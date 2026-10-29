vim9script

const MAX_BUFFERS = get(g:, 'fb_max_buffers', 500)       # cap on listed buffers
const PREVIEW_LINES = get(g:, 'fb_preview_lines', 200)   # lines shown in the preview
const MAX_SIZE = get(g:, 'fb_max_size', 2 * 1024 * 1024) # bytes; bigger unloaded files aren't previewed
const SORT = get(g:, 'fb_sort', 'mru')                   # 'mru', 'path' or 'number'

# ---------------------------------------------------------------------------
# State (one picker at a time)
# ---------------------------------------------------------------------------
var query = ''
var buffers: list<dict<any>> = []    # every listed buffer in display order, as
                                     # they were when the picker opened
var results: list<dict<any>> = []    # the buffers matching the query, at most
                                     # MAX_BUFFERS of them
var total = 0                        # how many buffers matched (results is capped)
var selected = 0
var current = 0                      # buffer the picker was opened from (%)
var alternate = 0                    # alternate buffer of that window (#)
var list_win = 0
var preview_win = 0
var cursor_hidden = false            # true while &t_ve is blanked (see Open())
var saved_t_ve = ''

# ---------------------------------------------------------------------------
# Highlight groups
# ---------------------------------------------------------------------------
def DefineHighlights()
  highlight default link FbSelected PmenuSel
  highlight default link FbFlags Comment
  highlight default link FbModified WarningMsg
  highlight default link FbInfo Comment
  highlight default link FbLineNr LineNr
  highlight default link FbCursorLine CursorLine
  highlight default link FbCursorLineNr CursorLineNr
  highlight default link FbSep Comment
  highlight default link FbPrompt Title
  highlight default link FbCursor Cursor
enddef

# ---------------------------------------------------------------------------
# Listing and filtering
# ---------------------------------------------------------------------------

# Most recently used first, led by the buffer you are in and then the
# alternate one (what Ctrl-^ goes to). They are pinned because Vim stamps a
# buffer only when it is entered, and only to the second: after a window
# switch, or a quick Ctrl-^ back and forth, they can look no newer than the
# rest. Other ties, such as buffers that were never entered, keep :ls order.
def Rank(b: dict<any>): number
  return b.nr == current ? 0 : b.nr == alternate ? 1 : 2
enddef

def ByRecent(a: dict<any>, b: dict<any>): number
  if Rank(a) != Rank(b)
    return Rank(a) - Rank(b)
  endif
  if a.used != b.used
    return b.used - a.used
  endif
  return a.nr - b.nr
enddef

def ByName(a: dict<any>, b: dict<any>): number
  if a.name ==# b.name
    return a.nr - b.nr
  endif
  return a.name <# b.name ? -1 : 1
enddef

# The name as :ls shows it: relative to the cwd when the file is below it,
# otherwise with the home directory as ~.
def DisplayName(b: dict<any>): string
  if b.name != ''
    return fnamemodify(b.name, ':~:.')
  endif
  var buftype = getbufvar(b.bufnr, '&buftype')
  return buftype == 'nofile' || buftype == 'nowrite' || buftype == 'prompt' ? '[Scratch]' : '[No Name]'
enddef

# One entry per listed buffer (the ones :ls shows), in display order.
def Snapshot(): list<dict<any>>
  var infos: list<dict<any>> = []
  for b in getbufinfo({buflisted: 1})
    add(infos, {
      nr: b.bufnr,
      name: DisplayName(b),
      path: b.name,
      loaded: b.loaded != 0,
      changed: b.changed != 0,
      lnum: b.lnum,              # where the cursor was (or is) in the buffer
      linecount: b.linecount,    # only meaningful when loaded
      used: get(b, 'lastused', 0),
    })
  endfor
  if SORT == 'path'
    sort(infos, ByName)
  elseif SORT != 'number'
    sort(infos, ByRecent)
  endif
  return infos
enddef

# The buffer you are in is never the default pick, since Enter would do
# nothing, unless it is the only match: start on the first other buffer.
def FirstChoice(): number
  for i in range(len(results))
    if results[i].nr != current
      return i
    endif
  endfor
  return 0
enddef

def ApplyQuery()
  var matches = buffers
  if query != ''
    # The query is a literal substring of the buffer's name. Smart-case, as in
    # fd and rg: case-insensitive unless the query has an uppercase letter.
    var exact = query !=# tolower(query)
    var needle = exact ? query : tolower(query)
    matches = filter(copy(buffers), (_, b) => stridx(exact ? b.name : tolower(b.name), needle) >= 0)
  endif
  total = len(matches)
  results = matches[: MAX_BUFFERS - 1]
  selected = FirstChoice()
enddef

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def Render()
  if list_win == 0
    return
  endif
  RenderList()
  RenderPreview()
enddef

# Cut a string to at most room display cells, keeping its start.
def ClipRight(s: string, room: number): string
  var out = strcharpart(s, 0, max([room, 0]))
  while strwidth(out) > room && out != ''
    out = strcharpart(out, 0, strchars(out) - 1)
  endwhile
  return out
enddef

# Cut a string to at most room display cells, keeping its end (marked by …).
def ClipLeft(s: string, room: number): string
  if strwidth(s) <= room
    return s
  endif
  var start = max([strchars(s) - room + 1, 0])
  var out = '…' .. strcharpart(s, start)
  while strwidth(out) > room && start < strchars(s)
    start += 1
    out = '…' .. strcharpart(s, start)
  endwhile
  return out
enddef

def RenderList()
  var width = popup_getpos(list_win).core_width
  var text: list<any> = []

  # Line 1 is always the prompt: "> query█". The drawn block is the cursor;
  # the real terminal cursor is hidden while the picker is open (see Open()).
  var prompt = '> ' .. query
  var prompt_pad = repeat(' ', max([width - strwidth(prompt) - 1, 0]))
  add(text, {text: prompt .. '█' .. prompt_pad, props: [
    {col: 1, length: len(prompt), type: 'FbPrompt'},
    {col: len(prompt) + 1, length: len('█'), type: 'FbCursor'},
  ]})
  add(text, {text: repeat('─', width), props: [{col: 1, length: len(repeat('─', width)), type: 'FbSep'}]})

  for i in range(len(results))
    var b = results[i]
    # Two flag columns on the right, as in :ls: % the buffer you are in,
    # # the alternate one, + unsaved changes.
    var mark = b.nr == current ? '%' : b.nr == alternate ? '#' : ' '
    var flags = ' ' .. mark .. (b.changed ? '+' : ' ')
    # Clip on the left so the file name itself stays visible.
    var name = ClipLeft(b.name, width - strwidth(flags))
    var pad = repeat(' ', max([width - strwidth(name) - strwidth(flags), 0]))
    var line = name .. pad .. flags
    var props: list<dict<any>> = []
    if i == selected
      props = [{col: 1, length: len(line), type: 'FbSelected'}]
    else
      var col = len(name .. pad) + 1  # the space in front of the flags
      if mark != ' '
        props += [{col: col + 1, length: 1, type: 'FbFlags'}]
      endif
      if b.changed
        props += [{col: col + 2, length: 1, type: 'FbModified'}]
      endif
    endif
    add(text, {text: line, props: props})
  endfor
  if empty(results)
    add(text, {text: ' no matches', props: [{col: 1, length: 11, type: 'FbInfo'}]})
  endif
  popup_settext(list_win, text)
  # Keep the selection scrolled into view. Selected buffer is at buffer line
  # (selected + 3): 2 header lines above it.
  win_execute(list_win, 'normal! ' .. (selected + 3) .. 'Gzz')
  popup_setoptions(list_win, {title: ' fb (' .. total .. (total == 1 ? ' buffer' : ' buffers') .. ') '})
enddef

# A file is binary if its first bytes contain a NUL (the rule rg uses).
def IsBinary(path: string): bool
  for byte in readblob(path, 0, 8192)
    if byte == 0
      return true
    endif
  endfor
  return false
enddef

def RenderPreview()
  if empty(results)
    popup_settext(preview_win, '')
    popup_setoptions(preview_win, {title: ''})
    return
  endif
  var b = results[selected]

  # A loaded buffer is previewed from memory, so unsaved changes show up. One
  # that is not loaded is read from the file, which may be anything: don't
  # read binary or huge ones.
  var note = ''
  var nlines = 0
  var file_lines: list<string> = []
  if b.loaded
    nlines = b.linecount
  elseif b.path == '' || !filereadable(b.path)
    note = ' cannot read file'
  elseif IsBinary(b.path)
    note = ' binary file'
  elseif getfsize(b.path) > MAX_SIZE
    note = ' file too large'
  else
    file_lines = readfile(b.path)
    nlines = len(file_lines)
  endif

  # Show PREVIEW_LINES lines centred on the line the cursor is (or was last)
  # on, so the preview opens where the buffer would.
  var lnum = min([max([b.lnum, 1]), max([nlines, 1])])
  var first = max([min([lnum - PREVIEW_LINES / 2, nlines - PREVIEW_LINES + 1]), 1])
  var last = min([nlines, first + PREVIEW_LINES - 1])
  var shown: list<string> = []
  if last >= first
    shown = b.loaded ? getbufline(b.nr, first, last) : file_lines[first - 1 : last - 1]
  endif

  var text: list<any> = []
  var digits = len(string(last))
  var maxw = popup_getpos(preview_win).core_width
  for n in range(first, first + len(shown) - 1)
    var prefix = printf('%' .. digits .. 'd ', n)
    # A loaded buffer has no size limit like a file does, so cut each line
    # to the pane width first: nothing past it is ever shown.
    var line = substitute(strcharpart(shown[n - first], 0, maxw), '\t', '  ', 'g')
    line = substitute(line, '[[:cntrl:]]', '?', 'g')
    # Clip to the pane ourselves so the window never has to scroll
    # horizontally: long lines are cut on the right, starts always visible.
    line = ClipRight(line, maxw - strwidth(prefix))
    if n == lnum
      # The cursor line is highlighted across the whole pane.
      line ..= repeat(' ', max([maxw - strwidth(prefix) - strwidth(line), 0]))
      add(text, {text: prefix .. line, props: [
        {col: 1, length: len(prefix), type: 'FbCursorLineNr'},
        {col: len(prefix) + 1, length: len(line), type: 'FbCursorLine'},
      ]})
    else
      add(text, {text: prefix .. line, props: [{col: 1, length: len(prefix), type: 'FbLineNr'}]})
    endif
  endfor
  if note != ''
    add(text, {text: note, props: [{col: 1, length: len(note), type: 'FbInfo'}]})
  endif

  popup_settext(preview_win, text)
  popup_setoptions(preview_win, {title: ' ' .. b.name .. ' '})
  # Put the cursor line in the middle of the pane, but never scroll so far
  # that blank space shows under the last line.
  var idx = lnum - first + 1
  var height = popup_getpos(preview_win).core_height
  var top = max([min([idx - height / 2, len(shown) - height + 1]), 1])
  win_execute(preview_win, 'normal! ' .. top .. 'Gzt' .. idx .. 'G')
enddef

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------
def Move(delta: number)
  if empty(results)
    return
  endif
  selected = (selected + delta + len(results)) % len(results)
  Render()
enddef

def OpenSelected()
  if empty(results)
    return
  endif
  var nr = results[selected].nr
  Close()
  try
    execute 'buffer ' .. nr
  catch
    # E.g. E37 when the current buffer has changes and 'hidden' is off.
    echohl ErrorMsg
    echomsg substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '')
    echohl None
  endtry
enddef

def Close()
  var wins = [list_win, preview_win]
  list_win = 0
  preview_win = 0
  for w in wins
    if w != 0
      popup_close(w)
    endif
  endfor
  if cursor_hidden
    &t_ve = saved_t_ve
    cursor_hidden = false
  endif
enddef

def Filter(winid: number, key: string): bool
  if key == "\<Esc>" || key == "\<C-c>"
    Close()
  elseif key == "\<CR>" || key == "\<C-y>"
    OpenSelected()
  elseif key == "\<C-n>" || key == "\<Down>" || key == "\<C-j>"
    Move(1)
  elseif key == "\<C-p>" || key == "\<Up>" || key == "\<C-k>"
    Move(-1)
  elseif key == "\<C-d>" || key == "\<C-f>"
    win_execute(preview_win, "normal! \<C-d>")
  elseif key == "\<C-b>" || key == "\<C-u>"
    win_execute(preview_win, "normal! \<C-u>")
  elseif key == "\<BS>" || key == "\<C-h>" || key == "\<Del>"
    query = strcharpart(query, 0, max([strchars(query) - 1, 0]))
    ApplyQuery()
    Render()
  elseif strchars(key) == 1 && char2nr(key) >= 32
    query ..= key
    ApplyQuery()
    Render()
  endif
  return true  # swallow every key while the picker is open
enddef

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
export def Open(initial: string)
  Close()
  DefineHighlights()
  for name in ['FbSelected', 'FbFlags', 'FbModified', 'FbInfo', 'FbLineNr', 'FbCursorLine', 'FbCursorLineNr', 'FbSep', 'FbPrompt', 'FbCursor']
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: name, combine: false})
    endif
  endfor

  query = initial
  current = bufnr('%')
  alternate = bufnr('#')
  buffers = Snapshot()
  ApplyQuery()

  # Hide the real terminal cursor, which would otherwise sit in the window
  # behind the popups. Vim only shows the cursor by sending t_ve, so blanking
  # it keeps the cursor hidden; Close() puts it back.
  saved_t_ve = &t_ve
  &t_ve = ''
  cursor_hidden = true

  # Each popup has a 1-cell border on every side, so it occupies content + 2.
  # Two popups side by side must fill &columns exactly; height leaves room for
  # the cmdline (&cmdheight) so nothing is hidden behind it.
  var outer_h = &lines - &cmdheight
  var inner_h = outer_h - 2
  var left_outer = &columns * 2 / 5
  var right_outer = &columns - left_outer
  var left_w = left_outer - 2
  var right_w = right_outer - 2

  list_win = popup_create('', {
    line: 1, col: 1,
    minwidth: left_w, maxwidth: left_w,
    minheight: inner_h, maxheight: inner_h,
    border: [],
    borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    zindex: 200,
    wrap: false,
    scrollbar: false,
    filter: Filter,
    mapping: false,
    callback: (_, _) => Close(),
  })
  preview_win = popup_create('', {
    line: 1, col: left_outer + 1,
    minwidth: right_w, maxwidth: right_w,
    minheight: inner_h, maxheight: inner_h,
    border: [],
    borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    zindex: 200,
    wrap: false,
    scrollbar: false,
  })
  # The pane is scrolled to put the cursor line in the middle: 'scrolloff'
  # would shift that.
  win_execute(preview_win, 'setlocal scrolloff=0')
  Render()
enddef

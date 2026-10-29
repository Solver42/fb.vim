vim9script

if exists('g:loaded_fb_vim')
  finish
endif
g:loaded_fb_vim = 1

command! -nargs=? -bar Fb call findbuffer#Open(<q-args>)

# Let a lowercase :fb work too.
cnoreabbrev <expr> fb getcmdtype() ==# ':' && getcmdline() ==# 'fb' ? 'Fb' : 'fb'

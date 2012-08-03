" Подсветить длину строки в пределах 80 символов
au BufWinEnter * let w:m1=matchadd('Search', '\%<81v.\%>77v', -1)
au BufWinEnter * let w:m2=matchadd('ErrorMsg', '\%>80v.\+', -1)

" Размер табулации по умолчанию
set shiftwidth=3
set softtabstop=3
set tabstop=3


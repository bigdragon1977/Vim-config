"=============================================================================
" File:        indexer.vim
" Author:      Dmitry Frank (dimon.frank@gmail.com)
" Last Change: 24 Mar 2011
" Version:     3.11
"=============================================================================
" See documentation in accompanying help file
" You may use this code in whatever way you see fit.

"TODO:
"
" ----------------
"  In 3.0
"
" Опцию типа "менять рабочую директорию при смене проекта", и менять ее только
" в том случае, если проект сменили, а не только файл.
"
" ----------------
"
" *) !!! Unsorted tags file is BAD. Please try to make SED work with sorted
"    tags file.
"
" *) test on paths with spaces, both on Linux and Windows
" *) test with one .vimprojects and .indexer_files file, define projectName
" *) rename indexer_ctagsDontSpecifyFilesIfPossible to indexer_ctagsUseDirs or
"    something
" *) make #pragma_index_none,
"         #pragma_index_dir,
"         #pragma_index_files
" *) ability to define one file in .indexer_files
" *) maybe checking whether or not ctags is version 5.8.1
" *) maybe checking whether or not sed is present
" *) maybe checking whether or not sed is correctly parsing ( \\\\ or \\ )
"



" --------- MAIN INDEXER VARIABLES ---------
"
" s:dProjFilesParsed - DICTIONARY with info about files ".vimprojects" and/or ".indexer_files"
"     [  <path_to__indexer_files_or__vimprojects>  ] - DICTIONARY KEY, example of key:
"                                                      "_home_user__indexer_files"
"        ["projects"] - DICTIONARY
"           [  <project_name>  ] - DICTIONARY KEY
"              ["pathsRoot"]
"              ["pathsForCtags"]
"              ["not_exist"]
"              ["files"]
"              ["paths"]
"        ["filename"] = (for example) "/home/user/.indexer_files"
"        ["type"] - "IndexerFile" or "ProjectFile"
"        ["sVimprjKey"] - key for s:dVimprjRoots
"
"
" s:dVimprjRoots - DICTIONARY with info about $INDEXER_PROJECT_ROOTs
"     [  <$INDEXER_PROJECT_ROOT>  ] - DICTIONARY KEY
"        ["cd_path"] - path for CD. Can't be empty.
"        ["proj_root"] - $INDEXER_PROJECT_ROOT. Can be empty (for "default")
"        ["path"] - path to .vimprj dir. Actually, this is
"                   "proj_root"."/.vimprj", if "proj_root" isn't empty.
"        ["mode"] - "IndexerFile" or "ProjectFile"
"        ..... - many indexer options like "indexerListFilename", etc.
"
"
" s:dFiles - DICTIONARY with info about all regular files
"     [  <bufnr('%')>  ] - DICTIONARY KEY
"        ["sVimprjKey"] - key for s:dVimprjRoots
"        ["projects"] - LIST 
"                             NOTE!!!
"                             At this moment only ONE project
"                             is allowed for each file
"           [0, 1, 2, ...] - LIST KEY. At this moment, only 0 is available
"              ["file"] - key for s:dProjFilesParsed
"              ["name"] - name of project
"           
"        
"  
"


" ************************************************************************************************
"                                   ASYNC COMMAND FUNCTIONS
" ************************************************************************************************

" ------------------ next 2 functions is directly from asynccommand.vim ---------------------

" Basic background task running is different on each platform
if has("win32")
   " Works in Windows (Win7 x64)
   function! <SID>IndexerAsync_Impl(tool_cmd, vim_cmd)
      let l:cmd = a:tool_cmd

      if !empty(a:vim_cmd)
         let l:cmd .= " & ".a:vim_cmd
      endif

      silent exec "!start /MIN cmd /c \"".l:cmd."\""
   endfunction
else
   " Works in linux (Ubuntu 10.04)
   function! <SID>IndexerAsync_Impl(tool_cmd, vim_cmd)

      let l:cmd = a:tool_cmd

      if !empty(a:vim_cmd)
         let l:cmd .= " ; ".a:vim_cmd
      endif

      silent exec "! (".l:cmd.") &"
   endfunction
endif

function! <SID>IndexerAsyncCommand(command, vim_func)

   " async works if only v:servername is not empty!
   " otherwise we should wait for output here.

   if !empty(v:servername)

      " String together and execute.
      let temp_file = tempname()

      " Grab output and error in case there's something we should see
      let tool_cmd = a:command . printf(&shellredir, temp_file)

      let vim_cmd = ""
      if !empty(a:vim_func)
         let vim_cmd = "vim --servername ".v:servername." --remote-expr \"" . a:vim_func . "('" . temp_file . "')\" "
      endif

      call <SID>IndexerAsync_Impl(tool_cmd, vim_cmd)
   else
      " v:servername is empty!
      " so, no async is present.
      let l:resp = system(a:command)
      let s:boolAsyncCommandInProgress = 0
   endif

endfunction

" ---------------------- my async level ----------------------

function! <SID>AddNewAsyncTask(dParams)
   "call add(s:lAsyncTasks, a:dParams)
   let s:dAsyncTasks[ s:iAsyncTaskLast ] = a:dParams
   let s:iAsyncTaskLast += 1
   if !s:boolAsyncCommandInProgress
      call <SID>_ExecNextAsyncTask()
   endif

endfunction

function! <SID>_ExecNextAsyncTask()

   "echo s:dAsyncTasks
   if !s:boolAsyncCommandInProgress && s:iAsyncTaskNext < s:iAsyncTaskLast
      let s:boolAsyncCommandInProgress = 1
      let l:dParams = s:dAsyncTasks[ s:iAsyncTaskNext ]
      unlet s:dAsyncTasks[ s:iAsyncTaskNext ]
      let s:iAsyncTaskNext += 1

      if l:dParams["mode"] == "AsyncModeCtags"

         let l:sCmd = <SID>GetCtagsCommand(l:dParams["data"])
         call <SID>IndexerAsyncCommand(l:sCmd, "Indexer_OnAsyncCommandComplete")

      elseif l:dParams["mode"] == "AsyncModeSed"

         call <SID>IndexerAsyncCommand(l:dParams["data"]["sSedCmd"], "Indexer_OnAsyncCommandComplete")

      elseif l:dParams["mode"] == "AsyncModeDelete"

         if filereadable(l:dParams["data"]["filename"])
            call delete(l:dParams["data"]["filename"])
         endif

         " we should make dummy async call
         call <SID>IndexerAsyncCommand("ctags --version", "Indexer_OnAsyncCommandComplete")

      elseif l:dParams["mode"] == "AsyncModeRename"

         if filereadable(l:dParams["data"]["filename_old"])
            if filereadable(l:dParams["data"]["filename_new"])
               call delete(l:dParams["data"]["filename_new"])
            endif
            call rename(l:dParams["data"]["filename_old"], l:dParams["data"]["filename_new"])
         endif

         " we should make dummy async call
         call <SID>IndexerAsyncCommand("ctags --version", "Indexer_OnAsyncCommandComplete")

      endif
   endif

endfunction

function! Indexer_OnAsyncCommandComplete(temp_file_name)

   let s:boolAsyncCommandInProgress = 0

   "exec "split " . a:temp_file_name
   "wincmd w
   "redraw

   call <SID>_ExecNextAsyncTask()

endfunction


" ************************************************************************************************
"                                   ADDITIONAL FUNCTIONS
" ************************************************************************************************

function! <SID>DeleteFile(filename)
   call <SID>AddNewAsyncTask({'mode' : 'AsyncModeDelete' , 'data' : { 'filename' : a:filename } })
endfunction

function! <SID>RenameFile(filename_old, filename_new)
   call <SID>AddNewAsyncTask({'mode' : 'AsyncModeRename' , 'data' : { 'filename_old' : a:filename_old, 'filename_new' : a:filename_new } })
endfunction

" applies all settings from .vimprj dir
function! <SID>ApplyVimprjSettings(sVimprjKey)

   let $INDEXER_PROJECT_ROOT = s:dVimprjRoots[ a:sVimprjKey ].proj_root

   let &tags = s:sTagsDefault
   let &path = s:sPathDefault

   if (!empty(s:indexer_defaultSettingsFilename))
      exec 'source '.s:indexer_defaultSettingsFilename
   endif

   if (!empty(s:dVimprjRoots[ a:sVimprjKey ].path))
      " sourcing all *vim files in .vimprj dir
      let l:lSourceFilesList = split(glob(s:dVimprjRoots[ a:sVimprjKey ]["path"].'/*vim'), '\n')
      let l:sThisFile = expand('%:p')
      for l:sFile in l:lSourceFilesList
         exec 'source '.l:sFile
      endfor

   endif

   "let l:sTmp .= "===".&ts
   "let l:tmp2 = input(l:sTmp)
   " для каждого проекта, в который входит файл, добавляем tags и path

   for l:lFileProjs in s:dFiles[ s:curFileNum ]["projects"]
      exec "set tags+=". s:dProjFilesParsed[ l:lFileProjs.file ]["projects"][ l:lFileProjs.name ]["tagsFilenameEscaped"]
      exec "set path+=".s:dProjFilesParsed[ l:lFileProjs.file ]["projects"][ l:lFileProjs.name ]["sPathsAll"]
   endfor

   " переключаем рабочую директорию
   exec "cd ".s:dVimprjRoots[ a:sVimprjKey ]["cd_path"]

endfunction


" returns if we should to skip this buffer ('skip' means not to generate tags
" for it)
function! <SID>NeedSkipBuffer(buf)
   if !empty(getbufvar(a:buf, "&buftype"))
      return 1
   endif

   "if empty(bufname(a:buf))
      "return 1
   "endif

   "if !empty(&g:swapfile) && empty(getbufvar(a:buf, "&swapfile"))
      "return 1
   "endif

   return 0
endfunction

" returns if buffer is changed (swithed) to another, or not
function! <SID>IsBufChanged()
    return (s:curFileNum != bufnr('%'))
endfunction

function! <SID>SetCurrentFile()
   if (exists("s:dFiles[".bufnr('%')."]"))
      let s:curFileNum = bufnr('%')
   else
      let s:curFileNum = 0
   endif
   let s:curVimprjKey = s:dFiles[ s:curFileNum ].sVimprjKey
endfunction

function! <SID>AddCurrentFile(sVimprjKey)
   let s:dFiles[ bufnr('%') ] = {'sVimprjKey' : a:sVimprjKey, 'projects': []}
   call <SID>SetCurrentFile()
endfunction

function! <SID>AddNewProjectToCurFile(sProjFileKey, sProjName)
   call add(s:dFiles[ s:curFileNum ].projects, {"file" : a:sProjFileKey, "name" : a:sProjName})
endfunction

function! <SID>GetKeyFromPath(sPath)
   return substitute(a:sPath, '[^a-zA-Z0-9_]', '_', 'g')
endfunction

" добавляет новый vimprj root, заполняет его текущими параметрами
function! <SID>AddNewVimprjRoot(sKey, sPath, sCdPath)

   if (!exists("s:dVimprjRoots['".a:sKey."']"))
      let s:dVimprjRoots[a:sKey] = {}
      let s:dVimprjRoots[a:sKey]["cd_path"] = a:sCdPath
      let s:dVimprjRoots[a:sKey]["proj_root"] = a:sPath
      if (!empty(a:sPath))
         let s:dVimprjRoots[a:sKey]["path"] = a:sPath.'/'.s:indexer_dirNameForSearch
      else
         let s:dVimprjRoots[a:sKey]["path"] = ""
      endif
      let s:dVimprjRoots[a:sKey]["useSedWhenAppend"]              = g:indexer_useSedWhenAppend
      let s:dVimprjRoots[a:sKey]["indexerListFilename"]           = g:indexer_indexerListFilename
      let s:dVimprjRoots[a:sKey]["projectsSettingsFilename"]      = g:indexer_projectsSettingsFilename
      let s:dVimprjRoots[a:sKey]["projectName"]                   = g:indexer_projectName
      let s:dVimprjRoots[a:sKey]["enableWhenProjectDirFound"]     = g:indexer_enableWhenProjectDirFound
      let s:dVimprjRoots[a:sKey]["ctagsCommandLineOptions"]       = g:indexer_ctagsCommandLineOptions
      let s:dVimprjRoots[a:sKey]["ctagsJustAppendTagsAtFileSave"] = g:indexer_ctagsJustAppendTagsAtFileSave
      let s:dVimprjRoots[a:sKey]["useDirsInsteadOfFiles"]         = g:indexer_ctagsDontSpecifyFilesIfPossible
      let s:dVimprjRoots[a:sKey]["mode"]                          = ""

   endif
endfunction


function! <SID>SetDefaultIndexerOptions()
   let g:indexer_useSedWhenAppend                = s:def_useSedWhenAppend
   let g:indexer_indexerListFilename             = s:def_indexerListFilename
   let g:indexer_projectsSettingsFilename        = s:def_projectsSettingsFilename
   let g:indexer_projectName                     = s:def_projectName
   let g:indexer_enableWhenProjectDirFound       = s:def_enableWhenProjectDirFound
   let g:indexer_ctagsCommandLineOptions         = s:def_ctagsCommandLineOptions
   let g:indexer_ctagsJustAppendTagsAtFileSave   = s:def_ctagsJustAppendTagsAtFileSave
   let g:indexer_ctagsDontSpecifyFilesIfPossible = s:def_ctagsDontSpecifyFilesIfPossible
endfunction


function! <SID>IndexerFilesList()
   if (s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
      echo "option g:indexer_ctagsDontSpecifyFilesIfPossible is ON. So, Indexer knows nothing about files."
   else
      if len(s:dFiles[ s:curFileNum ]["projects"]) > 0
         echo "* Files indexed: ".join( s:dProjFilesParsed[ s:dFiles[ s:curFileNum ]["projects"][0]["file"] ][ "projects" ][ s:dFiles[ s:curFileNum ]["projects"][0]["name"] ]["files"] )
      else
         echo "There's no projects indexed."
      endif
   endif
endfunction

" concatenates two lists preventing duplicates
function! <SID>ConcatLists(lExistingList, lAddingList)
   let l:lResList = a:lExistingList
   for l:sItem in a:lAddingList
      if (index(l:lResList, l:sItem) == -1)
         call add(l:lResList, l:sItem)
      endif
   endfor
   return l:lResList
endfunction

" <SID>ParsePath(sPath)
"   changing '\' to '/' or vice versa depending on OS (MS Windows or not) also calls simplify()
function! <SID>ParsePath(sPath)
   if (has('win32') || has('win64'))
      let l:sPath = substitute(a:sPath, '/', '\', 'g')
   else
      let l:sPath = substitute(a:sPath, '\', '/', 'g')
   endif
   let l:sPath = simplify(l:sPath)

   " removing last "/" or "\"
   let l:sLastSymb = strpart(l:sPath, (strlen(l:sPath) - 1), 1)
   if (l:sLastSymb == '/' || l:sLastSymb == '\')
      let l:sPath = strpart(l:sPath, 0, (strlen(l:sPath) - 1))
   endif
   return l:sPath
endfunction

" <SID>Trim(sString)
" trims spaces from begin and end of string
function! <SID>Trim(sString)
   return substitute(substitute(a:sString, '^\s\+', '', ''), '\s\+$', '', '')
endfunction

" <SID>IsAbsolutePath(path) <<<
"   this function from project.vim is written by Aric Blumer.
"   Returns true if filename has an absolute path.
function! <SID>IsAbsolutePath(path)
   if a:path =~ '^ftp:' || a:path =~ '^rcp:' || a:path =~ '^scp:' || a:path =~ '^http:'
      return 2
   endif
   let path=expand(a:path) " Expand any environment variables that might be in the path
   if path[0] == '/' || path[0] == '~' || path[0] == '\\' || path[1] == ':'
      return 1
   endif
   return 0
endfunction " >>>

" returns whether or not file exists in list
function! <SID>IsFileExistsInList(aList, sFilename)
   let l:sFilename = <SID>ParsePath(a:sFilename)
   if (index(a:aList, l:sFilename, 0, 1)) >= 0
      return 1
   endif
   return 0
endfunction





function! <SID>IndexerInfo()

   let l:sProjects = ""
   let l:sPathsRoot = ""
   let l:sPathsForCtags = ""
   let l:iFilesCnt = 0
   let l:iFilesNotFoundCnt = 0

   for l:lProjects in s:dFiles[ s:curFileNum ]["projects"]
      let l:dCurProject = s:dProjFilesParsed[ l:lProjects.file ]["projects"][ l:lProjects.name ]

      if !empty(l:sProjects)
         let l:sProjects .= ", "
      endif
      let l:sProjects .= l:lProjects.name

      if !empty(l:sPathsRoot)
         let l:sPathsRoot .= ", "
      endif
      let l:sPathsRoot .= join(l:dCurProject.pathsRoot, ', ')

      if !empty(l:sPathsForCtags)
          let l:sPathsForCtags .= ", "
      endif
      let l:sPathsForCtags .= join(l:dCurProject.pathsForCtags, ', ')
      let l:iFilesCnt += len(l:dCurProject.files)
      let l:iFilesNotFoundCnt += len(l:dCurProject.not_exist)

   endfor

   if (s:dVimprjRoots[ s:curVimprjKey ].mode == '')
      echo '* Filelist: not found'
   elseif (s:dVimprjRoots[ s:curVimprjKey ].mode == 'IndexerFile')
      echo '* Filelist: indexer file: '.s:dVimprjRoots[ s:curVimprjKey ].indexerListFilename
   elseif (s:dVimprjRoots[ s:curVimprjKey ].mode == 'ProjectFile')
      echo '* Filelist: project file: '.s:dVimprjRoots[ s:curVimprjKey ].projectsSettingsFilename
   else
      echo '* Filelist: Unknown'
   endif
   if (s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
      echo '* Index-mode: DIRS. (option g:indexer_ctagsDontSpecifyFilesIfPossible is ON)'
   else
      echo '* Index-mode: FILES. (option g:indexer_ctagsDontSpecifyFilesIfPossible is OFF)'
   endif
   echo '* When saving file: '.(s:dVimprjRoots[ s:curVimprjKey ].ctagsJustAppendTagsAtFileSave ? (s:dVimprjRoots[ s:curVimprjKey ].useSedWhenAppend ? 'remove tags for saved file by SED, and ' : '').'just append tags' : 'rebuild tags for whole project')
   if !empty(v:servername)
      echo '* Background tags generation: YES'
   else
      echo '* Background tags generation: NO. (because of servername is empty. Please read :help servername)'
   endif
   echo '* Projects indexed: '.l:sProjects
   if (!s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
      echo "* Files indexed: there's ".l:iFilesCnt.' files.' 
      " Type :IndexerFiles to list'
      echo "* Files not found: there's ".l:iFilesNotFoundCnt.' non-existing files. ' 
      ".join(s:dParseGlobal.not_exist, ', ')
   endif

   echo "* Root paths: ".l:sPathsRoot
   echo "* Paths for ctags: ".l:sPathsForCtags

   echo '* Paths (with all subfolders): '.&path
   echo '* Tags file: '.&tags
   echo '* Project root: '.($INDEXER_PROJECT_ROOT != '' ? $INDEXER_PROJECT_ROOT : 'not found').'  (Project root is a directory which contains "'.s:indexer_dirNameForSearch.'" directory)'
endfunction




" ************************************************************************************************
"                                   CTAGS UNIVERSAL FUNCTIONS
" ************************************************************************************************

" generates command to call ctags apparently params.
" params:
"   dParams {
"      append,    // 1 or 0
"      recursive, // 1 or 0
"      sTagsFile, // ".."
"      sFiles,    // ".."
"   }
function! <SID>GetCtagsCommand(dParams)
   let l:sAppendCode = ''
   let l:sRecurseCode = ''

   if (a:dParams.append)
      let l:sAppendCode = '-a'
   endif

   if (a:dParams.recursive)
      let l:sRecurseCode = '-R'
   endif

   " when using append without Sed we SHOULD use sort, because of if there's no sort, then
   " symbols will be doubled.
   "
   " when using append with Sed on Windows (cygwin) we SHOULD NOT use sort, because of if there's sort, then
   " tags file becomes damaged because of Sed's output is always with UNIX
   " line-ends. Ctags at Windows fails with this file.
   "
   if (s:dVimprjRoots[ s:curVimprjKey ].ctagsJustAppendTagsAtFileSave && s:dVimprjRoots[ s:curVimprjKey ].useSedWhenAppend && (has('win32') || has('win64')))
      let l:sSortCode = '--sort=no'
   else
      let l:sSortCode = '--sort=yes'
   endif

   let l:sTagsFile = '"'.a:dParams.sTagsFile.'"'
   let l:sCmd = 'ctags -f '.l:sTagsFile.' '.l:sRecurseCode.' '.l:sAppendCode.' '.l:sSortCode.' '.s:dVimprjRoots[ s:curVimprjKey ].ctagsCommandLineOptions.' '.a:dParams.sFiles

   "if (has('win32') || has('win64'))
      "let l:sCmd = 'ctags -f '.l:sTagsFile.' '.l:sRecurseCode.' '.l:sAppendCode.' '.l:sSortCode.' '.s:dVimprjRoots[ s:curVimprjKey ].ctagsCommandLineOptions.' '.a:dParams.sFiles
   "else
      "let l:sCmd = 'ctags -f '.l:sTagsFile.' '.l:sRecurseCode.' '.l:sAppendCode.' '.l:sSortCode.' '.s:dVimprjRoots[ s:curVimprjKey ].ctagsCommandLineOptions.' '.a:dParams.sFiles.' &'
   "endif
   "let wer = input(l:sCmd)
   return l:sCmd
endfunction

" executes ctags called with specified params.
" params look in comments to <SID>GetCtagsCommand()
function! <SID>ExecCtags(dParams)
   let l:dAsyncParams = {'mode' : 'AsyncModeCtags' , 'data' : a:dParams}
   call <SID>AddNewAsyncTask(l:dAsyncParams)
endfunction


" builds list of files (or dirs) and executes Ctags.
" If list is too long (if command is more that s:indexer_maxOSCommandLen)
" then executes ctags several times.
" params:
"   dParams {
"      lFilelist, // [..]
"      sTagsFile, // ".."
"      recursive  // 1 or 0
"   }
function! <SID>ExecCtagsForListOfFiles(dParams)

   " we need to know length of command to call ctags (without any files)
   let l:sCmd = <SID>GetCtagsCommand({'append': 1, 'recursive': a:dParams.recursive, 'sTagsFile': a:dParams.sTagsFile, 'sFiles': ""})
   let l:iCmdLen = strlen(l:sCmd)


   " now enumerating files
   let l:sFiles = ''
   for l:sCurFile in a:dParams.lFilelist

      let l:sCurFile = <SID>ParsePath(l:sCurFile)
      " if command with next file will be too long, then executing command
      " BEFORE than appending next file to list
      if ((strlen(l:sFiles) + strlen(l:sCurFile) + l:iCmdLen) > s:indexer_maxOSCommandLen)
         call <SID>ExecCtags({'append': 1, 'recursive': a:dParams.recursive, 'sTagsFile': a:dParams.sTagsFile, 'sFiles': l:sFiles})
         let l:sFiles = ''
      endif

      let l:sFiles = l:sFiles.' "'.l:sCurFile.'"'
   endfor

   if (l:sFiles != '')
      call <SID>ExecCtags({'append': 1, 'recursive': a:dParams.recursive, 'sTagsFile': a:dParams.sTagsFile, 'sFiles': l:sFiles})
   endif


endfunction



function! <SID>ExecSed(dParams)
   " linux: all should work
   " windows: cygwin works, non-cygwin needs \\ instead of \\\\
   let l:sFilenameToDeleteTagsWith = a:dParams.sFilenameToDeleteTagsWith

   let l:sFilenameToDeleteTagsWith = substitute(l:sFilenameToDeleteTagsWith, "\\\\", "\\\\\\\\\\\\\\\\", "g")
   let l:sFilenameToDeleteTagsWith = substitute(l:sFilenameToDeleteTagsWith, "\\.", "\\\\\\\\.", "g")
   let l:sFilenameToDeleteTagsWith = substitute(l:sFilenameToDeleteTagsWith, "\\/", "\\\\\\\\/", "g")

   "let l:sFilenameToDeleteTagsWith = substitute(l:sFilenameToDeleteTagsWith, "\\\\", "\\\\\\\\", "g")
   "let l:sFilenameToDeleteTagsWith = substitute(l:sFilenameToDeleteTagsWith, "\\.", "\\\\.", "g")
   "let l:sFilenameToDeleteTagsWith = substitute(l:sFilenameToDeleteTagsWith, "\\/", "\\\\/", "g")

   "let l:sCmd = "sed -e \"/".l:sFilenameToDeleteTagsWith."/d\" \"".a:dParams.sTagsFile."\" > \"".a:dParams.sTagsFile."_tmp\""
   "let l:sCmd = "sed -e \"/iqqqqqqqqqq/d\" < \"".a:dParams.sTagsFile."\" > \"".a:dParams.sTagsFile."_tmp\""
   "let df = input(l:sCmd)
   "let l:sCmd = "sed -e \"/^.*\\s".l:sFilenameToDeleteTagsWith."\\s.*$/d\" -i \"".a:dParams.sTagsFile."\""

   let l:sCmd = "sed -e \"/".l:sFilenameToDeleteTagsWith."/d\" -i \"".a:dParams.sTagsFile."\""

   let l:dAsyncParams = {'mode' : 'AsyncModeSed' , 'data' : {'sSedCmd' : l:sCmd}}
   call <SID>AddNewAsyncTask(l:dAsyncParams)

   "call <SID>RenameFile(a:dParams.sTagsFile."_tmp", a:dParams.sTagsFile)

   "let l:resp = system(l:sCmd)


   "if exists("*AsyncCommand")
      "call AsyncCommand(l:sCmd, "")
   "else
      "let l:resp = system(l:sCmd)
   "endif

endfunction

" ************************************************************************************************
"                                   CTAGS SPECIAL FUNCTIONS
" ************************************************************************************************

" update tags for one project.
" 
" params:
"     sProjFileKey - key for s:dProjFilesParsed
"     sProjName - project name in this projects file
"     sSavedFile - CAN BE EMPTY.
"                  if empty, then updating ALL tags for given project.
"                  otherwise, updating tags for just this file with Append.
function! <SID>UpdateTagsForProject(sProjFileKey, sProjName, sSavedFile)

   let l:sTagsFile = s:dProjFilesParsed[ a:sProjFileKey ]["projects"][ a:sProjName ].tagsFilename
   let l:dCurProject = s:dProjFilesParsed[a:sProjFileKey]["projects"][ a:sProjName ]

   if (!empty(a:sSavedFile) && filereadable(l:sTagsFile))
      " just appending tags from just saved file. (from one file!)
      if (s:dVimprjRoots[ s:curVimprjKey ].useSedWhenAppend)
         call <SID>ExecSed({'sTagsFile': l:sTagsFile, 'sFilenameToDeleteTagsWith': a:sSavedFile})
      endif
      call <SID>ExecCtags({'append': 1, 'recursive': 0, 'sTagsFile': l:sTagsFile, 'sFiles': a:sSavedFile})

   else
      " need to rebuild all tags.

      " deleting old tagsfile
      "if (filereadable(l:sTagsFile))
         "call delete(l:sTagsFile)
      "endif
      "let l:dAsyncParams = {'mode' : 'AsyncModeDelete' , 'data' : { 'filename' : l:sTagsFile } }

      call <SID>DeleteFile(l:sTagsFile."_tmp")

      " generating tags for files
      call <SID>ExecCtagsForListOfFiles({'lFilelist': l:dCurProject.files,          'sTagsFile': l:sTagsFile."_tmp",  'recursive': 0})
      " generating tags for directories
      call <SID>ExecCtagsForListOfFiles({'lFilelist': l:dCurProject.pathsForCtags,  'sTagsFile': l:sTagsFile."_tmp",  'recursive': 1})

      call <SID>RenameFile(l:sTagsFile."_tmp", l:sTagsFile)

   endif




   let s:dProjFilesParsed[ a:sProjFileKey ]["projects"][ a:sProjName ].boolIndexed = 1

endfunction

" re-read projects from given file, 
" update all tags for every project that is already indexed
"
function! <SID>UpdateTagsForEveryNeededProjectFromFile(sProjFileKey)

   call <SID>ParseProjectSettingsFile(a:sProjFileKey)

   " list of projects we should to index
   let l:lProjects = []

   " searching for all currently indexed projects from given projects file
   " (we should to reindex they all)
   for l:iBufNum in keys(s:dFiles)
      for l:dProjectFile in s:dFiles[ l:iBufNum ]["projects"]
         if (l:dProjectFile["file"] == a:sProjFileKey && index(l:lProjects, l:dProjectFile["name"]) == -1)
            call add(l:lProjects, l:dProjectFile["name"])
         endif
      endfor
   endfor


   for l:sProject in l:lProjects
      call <SID>UpdateTagsForProject(a:sProjFileKey, l:sProject, "")
   endfor

endfunction

"function! <SID>UpdateAllTagsForAllProjectsFromFile(sProjFileKey)
   "for l:sCurProjName in keys(s:dProjFilesParsed[ a:sProjFileKey ])
      "call UpdateTagsForProject(a:sProjFileKey, l:sCurProjName)
   "endfor
"endfunction








" ************************************************************************************************
"                         FUNCTIONS TO PARSE PROJECT FILE OR INDEXER FILE
" ************************************************************************************************

" возвращает dictionary:
" dResult[<название_проекта_1>][files]
"                              [paths]
"                              [not_exist]
"                              [pathsForCtags]
"                              [pathsRoot]
" dResult[<название_проекта_2>][files]
"                              [paths]
"                              [not_exist]
"                              [pathsForCtags]
"                              [pathsRoot]
" ...
"
" параметры:                             
" param aLines все строки файла (т.е. файл надо сначала прочитать)
" param projectName название проекта, который нужно прочитать.
"                   если пустой, то будут прочитаны
"                   все проекты из файла
" param dExistsResult уже существующий dictionary, к которому будут
" добавлены полученные результаты
"
function! <SID>GetDirsAndFilesFromIndexerList(aLines, projectName, dExistsResult)
   let l:aLines = a:aLines
   let l:dResult = a:dExistsResult
   let l:boolInNeededProject = (a:projectName == '' ? 1 : 0)
   let l:boolInProjectsParentSection = 0
   let l:sProjectsParentFilter = ''

   let l:sCurProjName = ''

   for l:sLine in l:aLines

      " if line is not empty
      if l:sLine !~ '^\s*$' && l:sLine !~ '^\s*\#.*$'

         " look for project name [PrjName]
         let l:myMatch = matchlist(l:sLine, '^\s*\[\([^\]]\+\)\]')

         if (len(l:myMatch) > 0)

            " check for PROJECTS_PARENT section

            if (strpart(l:myMatch[1], 0, 15) == 'PROJECTS_PARENT')
               " this is projects parent section
               let l:sProjectsParentFilter = ''
               let filterMatch = matchlist(l:myMatch[1], 'filter="\([^"]\+\)"')
               if (len(filterMatch) > 0)
                  let l:sProjectsParentFilter = filterMatch[1]
               endif
               let l:boolInProjectsParentSection = 1
            else
               let l:boolInProjectsParentSection = 0


               if (a:projectName != '')
                  if (l:myMatch[1] == a:projectName)
                     let l:boolInNeededProject = 1
                  else
                     let l:boolInNeededProject = 0
                  endif
               endif

               if l:boolInNeededProject
                  let l:sCurProjName = l:myMatch[1]
                  let l:dResult[l:sCurProjName] = { 'files': [], 'paths': [], 'not_exist': [], 'pathsForCtags': [], 'pathsRoot': [] }
               endif
            endif
         else

            if l:boolInProjectsParentSection
               " parsing one project parent

               let l:lFilter = split(l:sProjectsParentFilter, ' ')
               if (len(l:lFilter) == 0)
                  let l:lFilter = ['*']
               endif
               " removing \/* from end of path
               let l:projectsParent = substitute(<SID>Trim(l:sLine), '[\\/*]\+$', '', '')

               " creating list of projects
               let l:lProjects = split(expand(l:projectsParent.'/*'), '\n')
               let l:lIndexerFilesList = []
               for l:sPrj in l:lProjects
                  if (isdirectory(l:sPrj))
                     call add(l:lIndexerFilesList, '['.substitute(l:sPrj, '^.*[\\/]\([^\\/]\+\)$', '\1', '').']')
                     for l:sCurFilter in l:lFilter
                        call add(l:lIndexerFilesList, l:sPrj.'/**/'.l:sCurFilter)
                     endfor
                     call add(l:lIndexerFilesList, '')
                  endif
               endfor
               " parsing this list
               let l:dResult = <SID>GetDirsAndFilesFromIndexerList(l:lIndexerFilesList, a:projectName, l:dResult)
               
            elseif l:boolInNeededProject
               " looks like there's path
               if l:sCurProjName == ''
                  let l:sCurProjName = 'noname'
                  let l:dResult[l:sCurProjName] = { 'files': [], 'paths': [], 'not_exist': [], 'pathsForCtags': [], 'pathsRoot': [] }
               endif

               " we should separately expand every variable
               " like $BLABLABLA
               let l:sPatt = "\\v(\\$[a-zA-Z0-9_]+)"
               while (1)
                  let l:varMatch = matchlist(l:sLine, l:sPatt)
                  " if there's any $BLABLA in string
                  if (len(l:varMatch) > 0)
                     " changing one slash in value to doubleslash
                     let l:sTmp = substitute(expand(l:varMatch[1]), "\\\\", "\\\\\\\\", "g")
                     " changing $BLABLA to its value (doubleslashed)
                     let l:sLine = substitute(l:sLine, l:sPatt, l:sTmp, "")
                  else 
                     break
                  endif
               endwhile


               let l:sTmpLine = l:sLine
               " removing last part of path (removing all after last slash)
               let l:sTmpLine = substitute(l:sTmpLine, '^\(.*\)[\\/][^\\/]\+$', '\1', 'g')
               " removing asterisks at end of line
               let l:sTmpLine = substitute(l:sTmpLine, '^\([^*]\+\).*$', '\1', '')
               " removing final slash
               let l:sTmpLine = substitute(l:sTmpLine, '[\\/]$', '', '')

               let l:dResult[l:sCurProjName].pathsRoot = <SID>ConcatLists(l:dResult[l:sCurProjName].pathsRoot, [<SID>ParsePath(l:sTmpLine)])
               let l:dResult[l:sCurProjName].paths = <SID>ConcatLists(l:dResult[l:sCurProjName].paths, [<SID>ParsePath(l:sTmpLine)])

               " -- now we should generate all subdirs

               " getting string with all subdirs
               let l:sDirs = expand(l:sTmpLine."/**/")
               " removing final slash at end of every dir
               let l:sDirs = substitute(l:sDirs, '\v[\\/](\n|$)', '\1', 'g')
               " getting list from string
               let l:lDirs = split(l:sDirs, '\n')


               let l:dResult[l:sCurProjName].paths = <SID>ConcatLists(l:dResult[l:sCurProjName].paths, l:lDirs)


               if (!s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
                  " adding every file.
                  let l:dResult[l:sCurProjName].files = <SID>ConcatLists(l:dResult[l:sCurProjName].files, split(expand(substitute(<SID>Trim(l:sLine), '\\\*\*', '**', 'g')), '\n'))
               else
                  " adding just paths. (much more faster)
                  let l:dResult[l:sCurProjName].pathsForCtags = l:dResult[l:sCurProjName].pathsRoot
               endif
            endif

         endif
      endif

   endfor

   return l:dResult
endfunction

" getting dictionary with files, paths and non-existing files from indexer
" project file
function! <SID>GetDirsAndFilesFromIndexerFile(indexerFile, projectName)
   let l:aLines = readfile(a:indexerFile)
   let l:dResult = {}
   let l:dResult = <SID>GetDirsAndFilesFromIndexerList(l:aLines, a:projectName, l:dResult)
   return l:dResult
endfunction

" getting dictionary with files, paths and non-existing files from
" project.vim's project file
function! <SID>GetDirsAndFilesFromProjectFile(projectFile, projectName)
   let l:aLines = readfile(a:projectFile)
   " if projectName is empty, then we should add files from whole projectFile
   let l:boolInNeededProject = (a:projectName == '' ? 1 : 0)

   let l:iOpenedBraces = 0 " current count of opened { }
   let l:iOpenedBracesAtProjectStart = 0
   let l:aPaths = [] " paths stack
   let l:sLastFoundPath = ''

   let l:dResult = {}
   let l:sCurProjName = ''

   for l:sLine in l:aLines
      " ignoring comments
      if l:sLine =~ '^#' | continue | endif

      let l:sLine = substitute(l:sLine, '#.\+$', '' ,'')
      " searching for closing brace { }
      let sTmpLine = l:sLine
      while (sTmpLine =~ '}')
         let l:iOpenedBraces = l:iOpenedBraces - 1

         " if projectName is defined and there was last brace closed, then we
         " are finished parsing needed project
         if (l:iOpenedBraces <= l:iOpenedBracesAtProjectStart) && a:projectName != ''
            let l:boolInNeededProject = 0
            " TODO: total break
         endif
         call remove(l:aPaths, len(l:aPaths) - 1)

         let sTmpLine = substitute(sTmpLine, '}', '', '')
      endwhile

      " searching for blabla=qweqwe
      let l:myMatch = matchlist(l:sLine, '\s*\(.\{-}\)=\(.\{-}\)\\\@<!\(\s\|$\)')
      if (len(l:myMatch) > 0)
         " now we found start of project folder or subfolder
         "
         if !l:boolInNeededProject
            if (a:projectName != '' && l:myMatch[1] == a:projectName)
               let l:iOpenedBracesAtProjectStart = l:iOpenedBraces
               let l:boolInNeededProject = 1
            endif
         endif

         if l:boolInNeededProject && (l:iOpenedBraces == l:iOpenedBracesAtProjectStart)
            let l:sCurProjName = l:myMatch[1]
            let l:dResult[l:myMatch[1]] = { 'files': [], 'paths': [], 'not_exist': [], 'pathsForCtags': [], 'pathsRoot': [] }
         endif

         let l:sLastFoundPath = l:myMatch[2]
         " ADDED! Jkooij
         " Strip the path of surrounding " characters, if there are any
         let l:sLastFoundPath = substitute(l:sLastFoundPath, "\"\\(.*\\)\"", "\\1", "g")
         let l:sLastFoundPath = expand(l:sLastFoundPath) " Expand any environment variables that might be in the path
         let l:sLastFoundPath = <SID>ParsePath(l:sLastFoundPath)

      endif

      " searching for opening brace { }
      let sTmpLine = l:sLine
      while (sTmpLine =~ '{')

         if (<SID>IsAbsolutePath(l:sLastFoundPath) || len(l:aPaths) == 0)
            call add(l:aPaths, <SID>ParsePath(l:sLastFoundPath))
         else
            call add(l:aPaths, <SID>ParsePath(l:aPaths[len(l:aPaths) - 1].'/'.l:sLastFoundPath))
         endif

         let l:iOpenedBraces = l:iOpenedBraces + 1

         " adding current path to paths list if we are in needed project.
         if (l:boolInNeededProject && l:iOpenedBraces > l:iOpenedBracesAtProjectStart && isdirectory(l:aPaths[len(l:aPaths) - 1]))
            " adding to paths (that are with all subfolders)
            call add(l:dResult[l:sCurProjName].paths, l:aPaths[len(l:aPaths) - 1])
            " if last found path was absolute, then adding it to pathsRoot
            if (<SID>IsAbsolutePath(l:sLastFoundPath))
               call add(l:dResult[l:sCurProjName].pathsRoot, l:aPaths[len(l:aPaths) - 1])
            endif
         endif

         let sTmpLine = substitute(sTmpLine, '{', '', '')
      endwhile

      " searching for filename (if there's files-mode, not dir-mode)
      if (!s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
         if (l:sLine =~ '^[^={}]*$' && l:sLine !~ '^\s*$')
            " here we found something like filename
            "
            if (l:boolInNeededProject && l:iOpenedBraces > l:iOpenedBracesAtProjectStart)
               " we are in needed project
               "let l:sCurFilename = expand(<SID>ParsePath(l:aPaths[len(l:aPaths) - 1].'/'.<SID>Trim(l:sLine)))
               " CHANGED! Jkooij
               " expand() will change slashes based on 'shellslash' flag,
               " so call <SID>ParsePath() on expand() result for consistent slashes
               let l:sCurFilename = <SID>ParsePath(expand(l:aPaths[len(l:aPaths) - 1].'/'.<SID>Trim(l:sLine)))
               if (filereadable(l:sCurFilename))
                  " file readable! adding it
                  call add(l:dResult[l:sCurProjName].files, l:sCurFilename)
               elseif (!isdirectory(l:sCurFilename))
                  call add(l:dResult[l:sCurProjName].not_exist, l:sCurFilename)
               endif
            endif

         endif
      endif

   endfor

   " if there's dir-mode then let's set pathsForCtags = pathsRoot
   if (s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
      for l:sKey in keys(l:dResult)
         let l:dResult[l:sKey].pathsForCtags = l:dResult[l:sKey].pathsRoot
      endfor
      
   endif

   return l:dResult
endfunction


function! <SID>ParseProjectSettingsFile(sProjFileKey)

   let l:bufVimprjKey = s:curVimprjKey
   let s:curVimprjKey = s:dProjFilesParsed[ a:sProjFileKey ]["sVimprjKey"]
   call <SID>ApplyVimprjSettings(s:curVimprjKey)

   if (s:dProjFilesParsed[ a:sProjFileKey ]["type"] == 'IndexerFile')
      let s:dProjFilesParsed[a:sProjFileKey]["projects"] = <SID>GetDirsAndFilesFromIndexerFile(s:dProjFilesParsed[ a:sProjFileKey ]["filename"], s:dVimprjRoots[ s:dProjFilesParsed[ a:sProjFileKey ]["sVimprjKey"] ].projectName)
   elseif (s:dProjFilesParsed[ a:sProjFileKey ]["type"] == 'ProjectFile')
      let s:dProjFilesParsed[a:sProjFileKey]["projects"] = <SID>GetDirsAndFilesFromProjectFile(s:dProjFilesParsed[ a:sProjFileKey ]["filename"], s:dVimprjRoots[ s:dProjFilesParsed[ a:sProjFileKey ]["sVimprjKey"] ].projectName)
   endif

   let s:curVimprjKey = l:bufVimprjKey
   call <SID>ApplyVimprjSettings(s:curVimprjKey)

   " для каждого проекта из файла с описанием проектов
   " указываем параметры:
   "     boolIndexed = 0
   "     tagsFilename - имя файла тегов
   for l:sCurProjName in keys(s:dProjFilesParsed[ a:sProjFileKey ]["projects"])
      let s:dProjFilesParsed[a:sProjFileKey]["projects"][ l:sCurProjName ]["boolIndexed"] = 0

      "let l:sTagsFileWOPath = <SID>GetKeyFromPath(a:sProjFileKey.'_'.l:sCurProjName)
      "let l:sTagsFile = s:tagsDirname.'/'.l:sTagsFileWOPath

      " если директория для тегов не указана в конфиге - значит, юзаем
      " /path/to/.vimprojects_tags/  (или ....indexer_files)
      " и каждый файл называется так же, как называется проект.
      "
      " а если указана, то все теги кладем в нее, и названия файлов
      " тегов будут длинными, типа: /path/to/tags/D__projects_myproject_vimprj__indexer_files_BK90

      if empty(s:indexer_tagsDirname)
         " директория для тегов НЕ указана
         let l:sTagsDirname = s:dProjFilesParsed[a:sProjFileKey]["filename"]."_tags"
         let l:sTagsFileWOPath = <SID>GetKeyFromPath(l:sCurProjName)
      else
         " директория для тегов указана
         let l:sTagsDirname = s:indexer_tagsDirname
         let l:sTagsFileWOPath = <SID>GetKeyFromPath(a:sProjFileKey.'_'.l:sCurProjName)
      endif

      let l:sTagsFile = l:sTagsDirname.'/'.l:sTagsFileWOPath


      if !isdirectory(l:sTagsDirname)
         call mkdir(l:sTagsDirname, "p")
      endif

      let s:dProjFilesParsed[a:sProjFileKey]["projects"][ l:sCurProjName ]["tagsFilename"] = l:sTagsFile
      let s:dProjFilesParsed[a:sProjFileKey]["projects"][ l:sCurProjName ]["tagsFilenameEscaped"]=substitute(l:sTagsFile, ' ', '\\\\\\ ', 'g')

      let l:sPathsAll = ""
      for l:sPath in s:dProjFilesParsed[a:sProjFileKey]["projects"][l:sCurProjName].paths
         if isdirectory(l:sPath)
            let l:sPathsAll .= substitute(l:sPath, ' ', '\\ ', 'g').","
         endif
      endfor
      let s:dProjFilesParsed[a:sProjFileKey]["projects"][ l:sCurProjName ]["sPathsAll"] = l:sPathsAll

   endfor

endfunction

" Update tags for all projects that owns a file.
" (now every file can be owned just by one project)
"
" param a:sFile - string like '%' or '<afile>' or something like that.
" 
function! <SID>UpdateTagsForFile(sFile, boolJustAppendTags)
   let l:sSavedFile = <SID>ParsePath(expand(a:sFile.':p'))
   "let l:sSavedFilePath = <SID>ParsePath(expand('%:p:h'))

   " для каждого проекта, в который входит файл, ...

   for l:lFileProjs in s:dFiles[ s:curFileNum ]["projects"]
      let l:dCurProject = s:dProjFilesParsed[ l:lFileProjs.file ]["projects"][ l:lFileProjs.name ]

      " if saved file is present in non-existing filelist then moving file from non-existing list to existing list
      if (<SID>IsFileExistsInList(l:dCurProject.not_exist, l:sSavedFile))
         call remove(l:dCurProject.not_exist, index(l:dCurProject.not_exist, l:sSavedFile))
         call add(l:dCurProject.files, l:sSavedFile)
      endif

      if a:boolJustAppendTags
         call <SID>UpdateTagsForProject(l:lFileProjs.file, l:lFileProjs.name, l:sSavedFile)
      else
         call <SID>UpdateTagsForProject(l:lFileProjs.file, l:lFileProjs.name, "")
      endif

   endfor
endfunction




" ************************************************************************************************
"                    EVENT HANDLERS (OnBufSave, OnBufEnter, OnNewFileOpened)
" ************************************************************************************************

function! <SID>OnBufSave()
   call <SID>UpdateTagsForFile( '<afile>', s:dVimprjRoots[ s:curVimprjKey ].ctagsJustAppendTagsAtFileSave )
endfunction

function! <SID>OnBufEnter()
   if (<SID>NeedSkipBuffer('%'))
      return
   endif

   if (!<SID>IsBufChanged())
       return
   endif

   if empty(s:boolOnNewFileOpenedExecuted)
      call <SID>OnNewFileOpened()
   endif

   "let l:sTmp = input("OnBufWinEnter_".getbufvar('%', "&buftype"))

   call <SID>SetCurrentFile()

   call <SID>ApplyVimprjSettings(s:curVimprjKey)

endfunction



function! <SID>OnNewFileOpened()
   if (<SID>NeedSkipBuffer('%'))
      return
   endif

   let s:boolOnNewFileOpenedExecuted = 1

   "let l:sTmp = input("OnNewFileOpened_".getbufvar('%', "&buftype"))

   " actual tags dirname. If .vimprj directory will be found then this tags
   " dirname will be /path/to/dir/.vimprj/tags
   let g:indexer_indexedProjects = []
   let s:lPathsForCtags = []

   " ищем .vimprj
   let l:sVimprjKey = "default"

   if s:indexer_lookForProjectDir
      " need to look for .vimprj directory

      let l:i = 0
      let l:sCurPath = ''
      let $INDEXER_PROJECT_ROOT = ''
      while (l:i < s:indexer_recurseUpCount)
         if (isdirectory(expand('%:p:h').l:sCurPath.'/'.s:indexer_dirNameForSearch))
            let $INDEXER_PROJECT_ROOT = simplify(expand('%:p:h').l:sCurPath)
            exec 'cd '.substitute($INDEXER_PROJECT_ROOT, ' ', '\\ ', 'g')
            break
         endif
         let l:sCurPath = l:sCurPath.'/..'
         let l:i = l:i + 1
      endwhile

      if $INDEXER_PROJECT_ROOT != ''
         " project root was found.
         "
         " set directory for tags in .vimprj dir
         " let s:tagsDirname = $INDEXER_PROJECT_ROOT.'/'.s:indexer_dirNameForSearch.'/tags'

         " сбросить все g:indexer_.. на дефолтные
         call <SID>SetDefaultIndexerOptions()



         " sourcing all *vim files in .vimprj dir
         let l:lSourceFilesList = split(glob($INDEXER_PROJECT_ROOT.'/'.s:indexer_dirNameForSearch.'/*vim'), '\n')
         let l:sThisFile = expand('%:p')
         for l:sFile in l:lSourceFilesList
            exec 'source '.l:sFile
         endfor

         let l:sNewVimprjKey = <SID>GetKeyFromPath($INDEXER_PROJECT_ROOT)
         call <SID>AddNewVimprjRoot(l:sNewVimprjKey, $INDEXER_PROJECT_ROOT, $INDEXER_PROJECT_ROOT)
         "exec 'cd '.substitute($INDEXER_PROJECT_ROOT, ' ', '\\ ', 'g')

         " проверяем, не открыли ли мы файл из директории .vimprj
         let l:sPathToDirNameForSearch = $INDEXER_PROJECT_ROOT.'/'.s:indexer_dirNameForSearch
         let l:iPathToDNFSlen = strlen(l:sPathToDirNameForSearch)

         if (strpart(expand('%:p:h'), 0, l:iPathToDNFSlen) != l:sPathToDirNameForSearch)
            " нет, открытый файл - не из директории .vimprj, так что применяем
            " для него настройки из этой директории .vimprj
            let l:sVimprjKey = l:sNewVimprjKey
         endif
         

      endif

   endif

   call <SID>AddCurrentFile(l:sVimprjKey)


   " выясняем, какой файл проекта нужно юзать
   " смотрим: еще не парсили этот файл? (dProjFilesParsed)
   "    парсим
   " endif
   if (filereadable(s:dVimprjRoots[ s:curVimprjKey ].indexerListFilename))
      " read all projects from proj file
      let l:sProjFilename = s:dVimprjRoots[ s:curVimprjKey ].indexerListFilename
      let s:dVimprjRoots[ s:curVimprjKey ].mode = 'IndexerFile'

   elseif (filereadable(s:dVimprjRoots[ s:curVimprjKey ].projectsSettingsFilename))
      " read all projects from indexer file
      let l:sProjFilename = s:dVimprjRoots[ s:curVimprjKey ].projectsSettingsFilename
      let s:dVimprjRoots[ s:curVimprjKey ].mode = 'ProjectFile'

   else
      let l:sProjFilename = ''
      let s:dVimprjRoots[ s:curVimprjKey ].mode = ''
   endif

   let l:sProjFileKey = <SID>GetKeyFromPath(l:sProjFilename)

   if (l:sProjFileKey != "") " если нашли файл с описанием проектов
      if (!exists("s:dProjFilesParsed['".l:sProjFileKey."']"))
         " если этот файл еще не обрабатывали
         let s:dProjFilesParsed[ l:sProjFileKey ] = {"filename" : l:sProjFilename, "type" : s:dVimprjRoots[ s:curVimprjKey ].mode, "sVimprjKey" : s:curVimprjKey, "projects" : {} }

         call <SID>ParseProjectSettingsFile(l:sProjFileKey)

         " добавляем autocmd BufWritePost для файла с описанием проекта

         augroup Indexer_SavPrjFile
            "let l:sPrjFile = substitute(s:dProjFilesParsed[ l:sProjFileKey ]["filename"], '^.*[\\/]\([^\\/]\+\)$', '\1', '')
            let l:sPrjFile = substitute(s:dProjFilesParsed[ l:sProjFileKey ]["filename"], ' ', '\\\\\\ ', 'g')
            exec 'autocmd Indexer_SavPrjFile BufWritePost '.l:sPrjFile.' call <SID>UpdateTagsForEveryNeededProjectFromFile(<SID>GetKeyFromPath(expand("<afile>:p")))'
         augroup END


      endif

      "
      " Если пользователь не указал явно, какой проект он хочет проиндексировать,
      " ( опция g:indexer_projectName )
      " то
      " надо выяснить, какие проекты включать в список проиндексированных.
      " тут два варианта: 
      " 1) мы включаем проект, если открытый файл находится в
      "    любой его поддиректории
      " 2) мы включаем проект, если открытый файл прямо указан 
      "    в списке файлов проекта
      "    
      " есть опция: g:indexer_enableWhenProjectDirFound, она прямо указывает,
      "             нужно ли включать любой файл из поддиректории, или нет.
      "             Но еще есть опция g:indexer_ctagsDontSpecifyFilesIfPossible, и если
      "             она установлена, то плагин вообще не знает ничего про 
      "             конкретные файлы, поэтому мы должны себя вести также, какой
      "             если установлена первая опция.
      "
      " Еще один момент: если включаем проект только если открыт файл именно
      "                  из этого проекта, то просто сравниваем имя файла 
      "                  со списком файлов из проекта.
      "
      "                  А вот если включаем проект, если открыт файл из
      "                  поддиректории, то нужно еще подниматься вверх по дереву,
      "                  т.к. может оказаться, что директория, в которой
      "                  находится открытый файл, является поддиректорией
      "                  проекта, но не перечислена явно в файле проекта.
      "
      "
      if (s:dVimprjRoots[ s:curVimprjKey ].projectName == '')
         " пользователь не указал явно название проекта. Нам нужно выяснять.

         let l:iProjectsAddedCnt = 0
         let l:lProjects = []
         if (s:dVimprjRoots[ s:curVimprjKey ].enableWhenProjectDirFound || s:dVimprjRoots[ s:curVimprjKey ].useDirsInsteadOfFiles)
            " режим директорий
            for l:sCurProjName in keys(s:dProjFilesParsed[ l:sProjFileKey ]["projects"])
               let l:boolFound = 0
               let l:i = 0
               let l:sCurPath = ''
               while (!l:boolFound && l:i < 10)
                  "let l:tmp = input(simplify(expand('%:p:h').l:sCurPath)."====".join(s:dProjFilesParsed[ l:sProjFileKey ]["projects"][l:sCurProjName].paths, ', '))
                  if (<SID>IsFileExistsInList(s:dProjFilesParsed[ l:sProjFileKey ]["projects"][l:sCurProjName].paths, expand('%:p:h').l:sCurPath))
                     " user just opened file from subdir of project l:sCurProjName. 
                     " We should add it to result lists

                     " adding name of this project to g:indexer_indexedProjects
                     "call add(g:indexer_indexedProjects, l:sCurProjName)
                     if l:iProjectsAddedCnt == 0
                         call <SID>AddNewProjectToCurFile(l:sProjFileKey, l:sCurProjName)
                     endif
                     let l:iProjectsAddedCnt = l:iProjectsAddedCnt + 1
                     call add(l:lProjects, l:sCurProjName)
                     break
                  endif
                  let l:i = l:i + 1
                  let l:sCurPath = l:sCurPath.'/..'
               endwhile
            endfor

            if (l:iProjectsAddedCnt > 1)
                echoerr "Warning: directory '".simplify(expand('%:p:h'))."' exists in several projects: '".join(l:lProjects, ', ')."'. Only first is indexed."
                "let l:tmp = input(" ")
            endif


         else
            " режим файлов
            for l:sCurProjName in keys(s:dProjFilesParsed[ l:sProjFileKey ]["projects"])
               if (<SID>IsFileExistsInList(s:dProjFilesParsed[ l:sProjFileKey ]["projects"][l:sCurProjName].files, expand('%:p')))
                  " user just opened file from project l:sCurProjName. We should add it to
                  " result lists

                  " adding name of this project to g:indexer_indexedProjects
                  "call add(g:indexer_indexedProjects, l:sCurProjName)
                  if l:iProjectsAddedCnt == 0
                      call <SID>AddNewProjectToCurFile(l:sProjFileKey, l:sCurProjName)
                  endif
                  let l:iProjectsAddedCnt = l:iProjectsAddedCnt + 1
                  call add(l:lProjects, l:sCurProjName)

               endif
            endfor

            if (l:iProjectsAddedCnt > 1)
                echoerr "Warning: file '".simplify(expand('%:t'))."' exists in several projects: '".join(l:lProjects, ', ')."'. Only first is indexed."
                "let l:tmp = input(" ")
            endif

         endif

      else    " if projectName != ""
         " пользователь явно указал проект, который нужно проиндексировать
         for l:sCurProjName in keys(s:dProjFilesParsed[ l:sProjFileKey ]["projects"])
            if (l:sCurProjName == s:dVimprjRoots[ s:curVimprjKey ].projectName)
               call <SID>AddNewProjectToCurFile(l:sProjFileKey, l:sCurProjName)
            endif
         endfor

      endif 


      " теперь запускаем ctags для каждого непроиндексированного проекта, 
      " в который входит файл
      for l:sCurProj in s:dFiles[ s:curFileNum ].projects
         if (!s:dProjFilesParsed[ l:sCurProj.file ]["projects"][ l:sCurProj.name ].boolIndexed)
            " генерим теги
            call <SID>UpdateTagsForProject(l:sCurProj.file, l:sCurProj.name, "")
         endif

      endfor



   endif " if l:sProjFileKey != ""


   " для того, чтобы при входе в OnBufEnter сработал IsBufChanged, ставим
   " текущий номер буфера в 0
   let s:curFileNum = 0


endfunction



























" ************************************************************************************************
"                                             INIT
" ************************************************************************************************

" --------- init variables --------
if !exists('g:indexer_defaultSettingsFilename')
   let s:indexer_defaultSettingsFilename = ''
else
   let s:indexer_defaultSettingsFilename = g:indexer_defaultSettingsFilename
endif

if !exists('g:indexer_lookForProjectDir')
   let s:indexer_lookForProjectDir = 1
else
   let s:indexer_lookForProjectDir = g:indexer_lookForProjectDir
endif

if !exists('g:indexer_dirNameForSearch')
   let s:indexer_dirNameForSearch = '.vimprj'
else
   let s:indexer_dirNameForSearch = g:indexer_dirNameForSearch
endif

if !exists('g:indexer_recurseUpCount')
   let s:indexer_recurseUpCount = 10
else
   let s:indexer_recurseUpCount = g:indexer_recurseUpCount
endif

if !exists('g:indexer_tagsDirname')
   let s:indexer_tagsDirname = ''  "$HOME.'/.vimtags'
else
   let s:indexer_tagsDirname = g:indexer_tagsDirname
endif

if !exists('g:indexer_maxOSCommandLen')
   if (has('win32') || has('win64'))
      let s:indexer_maxOSCommandLen = 8000
   else
      let s:indexer_maxOSCommandLen = system("echo $(( $(getconf ARG_MAX) - $(env | wc -c) ))") - 200
   endif
else
   let s:indexer_maxOSCommandLen = g:indexer_maxOSCommandLen
endif





" following options can be overwrited in .vimprj folders

if !exists('g:indexer_useSedWhenAppend')
   let g:indexer_useSedWhenAppend = 1
endif

if !exists('g:indexer_indexerListFilename')
   let g:indexer_indexerListFilename = $HOME.'/.indexer_files'
endif

if !exists('g:indexer_projectsSettingsFilename')
   let g:indexer_projectsSettingsFilename = $HOME.'/.vimprojects'
endif

if !exists('g:indexer_projectName')
   let g:indexer_projectName = ''
endif

if !exists('g:indexer_enableWhenProjectDirFound')
   let g:indexer_enableWhenProjectDirFound = '1'
endif

if !exists('g:indexer_ctagsCommandLineOptions')
   let g:indexer_ctagsCommandLineOptions = '--c++-kinds=+p+l --fields=+iaS --extra=+q'
endif

if !exists('g:indexer_ctagsJustAppendTagsAtFileSave')
   if (has('win32') || has('win64'))
      let g:indexer_ctagsJustAppendTagsAtFileSave = 0
   else
      let g:indexer_ctagsJustAppendTagsAtFileSave = 1
   endif
endif

if !exists('g:indexer_ctagsDontSpecifyFilesIfPossible')
   let g:indexer_ctagsDontSpecifyFilesIfPossible = '0'
endif


let s:def_useSedWhenAppend                = g:indexer_useSedWhenAppend
let s:def_indexerListFilename             = g:indexer_indexerListFilename
let s:def_projectsSettingsFilename        = g:indexer_projectsSettingsFilename
let s:def_projectName                     = g:indexer_projectName
let s:def_enableWhenProjectDirFound       = g:indexer_enableWhenProjectDirFound
let s:def_ctagsCommandLineOptions         = g:indexer_ctagsCommandLineOptions
let s:def_ctagsJustAppendTagsAtFileSave   = g:indexer_ctagsJustAppendTagsAtFileSave
let s:def_ctagsDontSpecifyFilesIfPossible = g:indexer_ctagsDontSpecifyFilesIfPossible

" -------- init commands ---------

if exists(':IndexerInfo') != 2
   command -nargs=? -complete=file IndexerInfo call <SID>IndexerInfo()
endif
if exists(':IndexerFiles') != 2
   command -nargs=? -complete=file IndexerFiles call <SID>IndexerFilesList()
endif
if exists(':IndexerRebuild') != 2
   command -nargs=? -complete=file IndexerRebuild call <SID>UpdateTagsForFile('%', 0)
endif


" DICTIONARY for acync commands
"let s:dAsyncData = {}
let s:dAsyncTasks = {}
let s:iAsyncTaskNext = 0
let s:iAsyncTaskLast = 0
let s:boolAsyncCommandInProgress = 0
let s:boolOnNewFileOpenedExecuted = 0

" запоминаем начальные &tags, &path
let s:sTagsDefault = &tags
let s:sPathDefault = &path

" задаем пустые массивы с данными
let s:dVimprjRoots = {}
let s:dProjFilesParsed = {}
let s:dFiles = {}
let s:curFileNum = 0

" создаем дефолтный "проект"
call <SID>AddNewVimprjRoot("default", "", getcwd())
let s:dFiles[ 0 ] = {'sVimprjKey' : 'default', 'projects': []}

" указываем обработчик открытия нового файла: OnNewFileOpened
augroup Indexer_LoadFile
   autocmd! Indexer_LoadFile BufReadPost
   autocmd Indexer_LoadFile BufReadPost * call <SID>OnNewFileOpened()
   autocmd Indexer_LoadFile BufNewFile * call <SID>OnNewFileOpened()
augroup END

" указываем обработчик входа в другой буфер: OnBufEnter
autocmd BufEnter * call <SID>OnBufEnter()

autocmd BufWritePost * call <SID>OnBufSave()


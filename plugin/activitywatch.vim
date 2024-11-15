if exists("g:loaded_activitywatch")
        finish
endif
let g:loaded_activitywatch = 1

" compatibility mode which set this script to run with default vim settings
let s:save_cpo = &cpo
set cpo&vim

let s:nvim = has('nvim')

let s:last_heartbeat = localtime()
let s:file = ''
let s:language = ''
let s:project = ''

let s:last_branch_update = 0
let s:is_changed_branch = 0
let s:branch = ''

let s:connected = 0
let s:apiurl_host = get(g:, 'aw_apiurl_host', '127.0.0.1')
let s:apiurl_port = get(g:, 'aw_apiurl_port', '5600')
let s:api_timeout = get(g:, 'aw_api_timeout', 2)
let s:base_apiurl = printf('http://%s:%s/api/0', s:apiurl_host, s:apiurl_port)
let s:hostname = get(g:, 'aw_hostname', hostname())
let s:bucketname = printf('aw-watcher-vim_%s', s:hostname)
let s:bucket_apiurl = printf('%s/buckets/%s', s:base_apiurl, s:bucketname)
let s:heartbeat_apiurl = printf('%s/heartbeat?pulsetime=30', s:bucket_apiurl)

" dict of all responses
" the key is the jobid and the value the HTTP status code
let s:http_response_code = {}

function! HTTPPostJson(url, data)
    let l:req = ['curl', '-s', a:url,
        \ '-H', 'Content-Type: application/json',
        \ '-X', 'POST',
        \ '-d', json_encode(a:data),
        \ '-o', '/dev/null',
        \ '-m', s:api_timeout,
        \ '-w', "%{http_code}"]
    if s:nvim
        let l:req_job = jobstart(l:req,
            \ {"detach": 1,
            \  "on_stdout": "HTTPPostOnStdoutNeovim",
            \  "on_exit": "HTTPPostOnExitNeovim",
        \ })
    else
        let l:req_job = job_start(l:req,
            \ {"out_cb": "HTTPPostOnStdoutVim",
            \  "close_cb": "HTTPPostOnExitVim",
            \  "in_mode": "raw",
        \ })
    endif
endfunc

function! HTTPPostOnExitNeovim(jobid, exitcode, eventtype)
    let l:jobid_str = printf('%d', a:jobid)
    let l:status_code = str2nr(s:http_response_code[l:jobid_str][0])
    call HTTPPostOnExit(l:jobid_str, l:status_code)
endfunc

function! HTTPPostOnExitVim(jobmsg)
    " cut out channelnum from string 'channel X running'
    let l:jobid_str = substitute(a:jobmsg, '[ A-Za-z]*', '', "g")
    let l:status_code = str2nr(s:http_response_code[l:jobid_str])
    call HTTPPostOnExit(l:jobid_str, l:status_code)
endfunc

function! HTTPPostOnExit(jobid_str, status_code)
    if a:status_code == 0
        " We cannot connect to aw-server
        echoerr "aw-watcher-vim: Failed to connect to aw-server, logging will be disabled. You can retry to connect with ':AWStart'"
        let s:connected = 0
    elseif a:status_code >= 100 && a:status_code < 300 || a:status_code == 304
        " We are connected!
        let s:connected = 1
    else
        " aw-server didn't like our request
        echoerr printf("aw-watcher-vim: aw-server did not accept our request with status code %d. See aw-server logs for reason or stop aw-watcher-vim with :AWStop", a:status_code)
    endif
    " Cleanup response code
    unlet s:http_response_code[a:jobid_str]
endfunc

function! HTTPPostOnStdoutVim(jobmsg, data)
    " cut out channelnum from string 'channel X running'
    let l:jobid_str = substitute(a:jobmsg, '[ A-Za-z]*', '', "g")
    let s:http_response_code[l:jobid_str] = a:data
    "echo printf('aw-watcher-vim job %d stdout: %s', l:jobid_str, json_encode(a:data))
endfunc

function! HTTPPostOnStdoutNeovim(jobid, data, event)
    if a:data != ['']
        let l:jobid_str = printf('%d', a:jobid)
        let s:http_response_code[l:jobid_str] = a:data
        "echo printf('aw-watcher-vim job %d stdout: %s', a:jobid, json_encode(a:data))
    endif
endfunc

function! s:CreateBucket()
    let l:body = {
        \ 'name': s:bucketname,
        \ 'hostname': s:hostname,
        \ 'client': 'aw-watcher-vim',
        \ 'type': 'app.editor.activity'
    \}
    call HTTPPostJson(s:bucket_apiurl, l:body)
endfunc

function! s:GitBranchOnStdout(jobid, data, event)
    if a:data != ['']
        let l:current_branch = a:data[0]
        let s:is_changed_branch = current_branch == s:branch ? 0 : 1
        let s:branch = current_branch
    endif
endfunc

function! s:GitBranchOnExit(jobid, exitcode, eventtype)
    if a:exitcode != 0
        let s:branch = ''
    endif
endfunc

function! s:RefreshGitBranch(localtime)
    if a:localtime - s:last_branch_update > 5
        let s:last_branch_update = a:localtime
        let l:cmd_result = jobstart('git branch --show-current', {'on_stdout': 's:GitBranchOnStdout', 'on_exit': 's:GitBranchOnExit'})
    endif
endfunc

function! s:Heartbeat()
    " Only send heartbeats if we can connect to aw-server
    if s:connected < 1
        return
    endif
    let l:duration = 0
    let l:localtime = localtime()
    let l:timestamp = strftime('%FT%H:%M:%S%z')
    let l:file = expand('%:p')
    let l:language = &filetype
    let l:project = getcwd()
    call s:RefreshGitBranch(l:localtime)
    " Only send heartbeat if data was changed or more than 1 second has passed
    " since last heartbeat
    if    s:file != l:file ||
        \ s:language != l:language ||
        \ s:project != l:project ||
        \ s:is_changed_branch == 1 ||
        \ l:localtime - s:last_heartbeat > 1

        let l:req_body = {
            \ 'duration': 0,
            \ 'timestamp': l:timestamp,
            \ 'data': {
                \ 'file': l:file,
                \ 'language': l:language,
                \ 'project': l:project
            \ }
        \}
        if s:branch != ''
            let l:req_body['data']['branch'] = s:branch
        endif
        call HTTPPostJson(s:heartbeat_apiurl, l:req_body)
        let s:file = l:file
        let s:language = l:language
        let s:project = l:project
        let s:last_heartbeat = l:localtime
    endif
endfunc

function! AWStart()
    call s:CreateBucket()
    call s:RefreshGitBranch(localtime())
endfunc

function! AWStop()
    let s:connected = 0
endfunc

augroup ActivityWatch
    autocmd VimEnter * call AWStart()
    autocmd BufEnter,CursorMoved,CursorMovedI * call s:Heartbeat()
    autocmd CmdlineEnter,CmdlineChanged * call s:Heartbeat()
augroup END

command! AWHeartbeat call s:Heartbeat()
command! AWStart call AWStart()
command! AWStop call AWStop()
command! AWStatus echom printf('aw-watcher-vim running: %b', s:connected)

" reset compatibility mode
let &cpo = s:save_cpo

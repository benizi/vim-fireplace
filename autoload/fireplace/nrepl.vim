" Fireplace nREPL session

if exists("g:autoloaded_fireplace_nrepl")
  finish
endif
let g:autoloaded_fireplace_nrepl = 1

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '<SNR>\d\+_'),''))
endfunction

if !exists('s:id')
  let s:vim_id = localtime()
  let s:id = 0
endif
function! fireplace#nrepl#next_id() abort
  let s:id += 1
  return 'fireplace-'.hostname().'-'.s:vim_id.'-'.s:id
endfunction

if !exists('g:fireplace_nrepl_sessions')
  let g:fireplace_nrepl_sessions = {}
endif

augroup fireplace_nrepl_connection
  autocmd!
  autocmd VimLeave * for s:session in values(g:fireplace_nrepl_sessions)
        \ |   call s:session.close()
        \ | endfor
augroup END

function! fireplace#nrepl#for(transport) abort
  let client = copy(s:nrepl)
  let client.transport = a:transport
  let client.session = client.process({'op': 'clone', 'session': 0})['new-session']
  let client.describe = client.process({'op': 'describe', 'verbose?': 1})
  if client.describe.versions.nrepl.major == 0 &&
        \ client.describe.versions.nrepl.minor < 2
    throw 'nREPL: 0.2.0 or higher required'
  endif
  if client.has_op('classpath')
    let response = client.message({'op': 'classpath'})[0]
    if type(get(response, 'value')) == type([])
      let client._path = response.value
    endif
  endif
  if !has_key(client, '_path')
    let response = client.process({'op': 'eval', 'code':
          \ '[(System/getProperty "path.separator") (System/getProperty "java.class.path")]', 'session': ''})
    let client._path = split(eval(response.value[-1][5:-2]), response.value[-1][2])
  endif
  let g:fireplace_nrepl_sessions[client.session] = client
  return client
endfunction

function! s:nrepl_close() dict abort
  if has_key(self, 'session')
    try
      unlet! g:fireplace_nrepl_sessions[self.session]
      call self.message({'op': 'close'}, 'ignore')
    catch
    finally
      unlet self.session
    endtry
  endif
  call self.transport.close()
  return self
endfunction

function! s:nrepl_clone() dict abort
  let client = copy(self)
  if has_key(self, 'session')
    let client.session = client.process({'op': 'clone'})['new-session']
    let g:fireplace_nrepl_sessions[client.session] = client
  endif
  return client
endfunction

function! s:nrepl_path() dict abort
  return self._path
endfunction

function! fireplace#nrepl#combine(responses)
  let combined = {'status': [], 'session': []}
  for response in a:responses
    for key in keys(response)
      if key ==# 'id' || key ==# 'ns'
        let combined[key] = response[key]
      elseif key ==# 'value'
        let combined.value = extend(get(combined, 'value', []), [response.value])
      elseif key ==# 'status'
        for entry in response[key]
          if index(combined[key], entry) < 0
            call extend(combined[key], [entry])
          endif
        endfor
      elseif key ==# 'session'
        if index(combined[key], response[key]) < 0
          call extend(combined[key], [response[key]])
        endif
      elseif type(response[key]) == type('')
        let combined[key] = get(combined, key, '') . response[key]
      else
        let combined[key] = response[key]
      endif
    endfor
  endfor
  return combined
endfunction

function! s:nrepl_process(msg) dict abort
  let combined = fireplace#nrepl#combine(self.message(a:msg))
  if index(combined.status, 'error') < 0
    return combined
  endif
  throw 'nREPL: ' . tr(combined.status[0], '-', ' ')
endfunction

function! s:nrepl_eval(expr, ...) dict abort
  let msg = {"op": "eval"}
  let msg.code = a:expr
  let options = a:0 ? a:1 : {}
  if has_key(options, 'ns')
    let msg.ns = options.ns
  elseif has_key(self, 'ns')
    let msg.ns = self.ns
  endif
  if has_key(options, 'session')
    let msg.session = options.session
  endif
  let msg.id = fireplace#nrepl#next_id()
  if has_key(options, 'file_path')
    let msg.op = 'load-file'
    let msg['file-path'] = options.file_path
    let msg['file-name'] = fnamemodify(options.file_path, ':t')
    if has_key(msg, 'ns')
      let msg.file = "(in-ns '".msg.ns.") ".msg.code
      call remove(msg, 'ns')
    else
      let msg.file = msg.code
    endif
    call remove(msg, 'code')
  endif
  try
    let response = self.process(msg)
  catch /^Vim:Interrupt$/
    if has_key(msg, 'session')
      call self.message({'op': 'interrupt', 'session': msg.session, 'interrupt-id': msg.id}, 'ignore')
    endif
    throw 'Clojure: Interrupt'
  endtry
  if has_key(response, 'ns') && !has_key(options, 'ns')
    let self.ns = response.ns
  endif

  if has_key(response, 'ex') && !empty(get(msg, 'session', 1))
    let response.stacktrace = s:extract_last_stacktrace(self, get(msg, 'session', self.session))
  endif

  if has_key(response, 'value')
    let response.value = response.value[-1]
  endif
  return response
endfunction

function! s:extract_last_stacktrace(nrepl, session) abort
  if a:nrepl.has_op('stacktrace')
    let stacktrace = filter(a:nrepl.message({'op': 'stacktrace', 'session': a:session}), 'has_key(v:val, "file")')
    if !empty(stacktrace)
      return map(stacktrace, 'v:val.class.".".v:val.method."(".v:val.file.":".v:val.line.")"')
    endif
  endif
  let format_st = '(symbol (str "\n\b" (apply str (interleave (repeat "\n") (map str (.getStackTrace *e)))) "\n\b\n"))'
  let stacktrace = split(get(split(a:nrepl.process({'op': 'eval', 'code': '['.format_st.' *3 *2 *1]', 'ns': 'user', 'session': a:session}).value[0], "\n\b\n"), 1, ""), "\n")
  call a:nrepl.message({'op': 'eval', 'code': '(*1 1)', 'ns': 'user', 'session': a:session})
  call a:nrepl.message({'op': 'eval', 'code': '(*2 2)', 'ns': 'user', 'session': a:session})
  call a:nrepl.message({'op': 'eval', 'code': '(*3 3)', 'ns': 'user', 'session': a:session})
  return stacktrace
endfunction

let s:keepalive = tempname()
call writefile([getpid()], s:keepalive)

function! s:nrepl_prepare(msg) dict abort
  let msg = copy(a:msg)
  if !has_key(msg, 'id')
    let msg.id = fireplace#nrepl#next_id()
  endif
  if empty(get(msg, 'session', 1))
    unlet msg.session
  elseif !has_key(msg, 'session')
    let msg.session = self.session
  endif
  return msg
endfunction

function! fireplace#nrepl#callback(body, type, fn)
  let response = {'body': a:body, 'type': a:type}
  if has_key(a:body, 'session')
    let response.session = g:fireplace_nrepl_sessions[a:body.session]
  endif
  call call(a:fn, [response])
endfunction

function! s:nrepl_call(msg, ...) dict abort
  let terms = a:0 ? a:1 : ['done']
  let sels = a:0 > 1 ? a:2 : {}
  return call(self.transport.call, [a:msg, terms, sels] + a:000[2:-1], self.transport)
endfunction

function! s:nrepl_message(msg, ...) dict abort
  let msg = self.prepare(a:msg)
  let sel = {'id': msg.id}
  return call(self.call, [msg, ['done'], sel] + a:000, self)
endfunction

function! s:nrepl_has_op(op) dict abort
  return has_key(self.describe.ops, a:op)
endfunction

let s:nrepl = {
      \ 'close': s:function('s:nrepl_close'),
      \ 'clone': s:function('s:nrepl_clone'),
      \ 'prepare': s:function('s:nrepl_prepare'),
      \ 'call': s:function('s:nrepl_call'),
      \ 'message': s:function('s:nrepl_message'),
      \ 'eval': s:function('s:nrepl_eval'),
      \ 'has_op': s:function('s:nrepl_has_op'),
      \ 'path': s:function('s:nrepl_path'),
      \ 'process': s:function('s:nrepl_process')}

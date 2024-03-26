# Qooil

A file transfer utility written in Zig.

## Running

The server and client reside in the same binary. run `qooil -h` for help:

```
Qooil - An FTP-like file transportation utility
 -s               run server
 -c               run client (default)
 -a               host/address to bind/connect
 -p               port to listen/connect (default is 7070)
 -h               show this help
 -j               server thread count

Examples:

 qooil
 # connect to server running on localhost on port 7070

 qooil -s -p 7777 -a 127.0.0.1 -j 100
 # run server on port 7777 and loopback interface
 # with thread pool size of 100 threads
```

## Repl Commands

After connecting to the server, the client gives you a REPL to communicate to the server:

```
> help

cat                     cat <file> | print file content to terminal
cd                      cd <dir> | change CWD to dir
delete                  delete <file> | delete file
get                     get <remote-path> <local-path> | download file from server
help                    print this help
ls                      ls [dir] | shows entries in CWD or dir
ping                    check whether server is up or not
put                     put <remote-path> <local-path> | upload file to server
pwd                     show CWD
quit                    close connection

```

## Todo
- [ ] directory manipulation
- [ ] client download manager & download history
- [ ] parallel transfers
- [ ] multi-root
- [ ] proxy/mirror
- [ ] authentication
- [ ] per-dir/file permissions
- [ ] compression
- [ ] encryption
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

change working directory:
```
> cd dir
```

listing nodes in a directory:
```
> ls
```

printing a file to terminal:
```
> cat file
```
downloading a file to local system:
```
> get remote-file local-address
```

exiting:
```
> quit
```

## Todo
- [x] upload file
- [ ] remove file
- [ ] directory manipulation
- [ ] client download manager & download history
- [ ] parallel transfers
- [ ] multi-root
- [ ] proxy/mirror
- [ ] authentication
- [ ] per-dir/file permissions
- [ ] compression
- [ ] encryption
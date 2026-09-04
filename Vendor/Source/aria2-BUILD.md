# Rebuilding the bundled aria2c

The bundled `aria2c` was built from the unmodified official
`aria2-1.37.0.tar.xz` source archive included beside this file. The builds use
AppleTLS and macOS system zlib, and disable protocols not needed by BiliFetch.

For both architectures, configure out of tree with these common switches:

```text
--disable-bittorrent --disable-metalink --disable-websocket --disable-nls
--disable-shared --enable-static
--without-gnutls --without-libnettle --without-libgmp --without-libgcrypt
--without-openssl --without-sqlite3 --without-libxml2 --without-libexpat
--without-libcares --without-libssh2
```

On an Apple Silicon Mac, use Clang once with `-arch arm64` and once with
`-arch x86_64`. Set `CFLAGS` and `CXXFLAGS` to
`-O2 -mmacosx-version-min=13.0`, set `LDFLAGS` to
`-mmacosx-version-min=13.0`, and pass the matching host triplet to `configure`.
Run `make`, then combine the two `src/aria2c` executables:

```sh
lipo -create build-arm64/src/aria2c build-x86_64/src/aria2c -output aria2c
```

The resulting executable requires only macOS system frameworks/libraries.

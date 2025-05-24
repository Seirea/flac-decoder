# flac decoder

[FLAC](https://xiph.org/flac/) Decoder Implementation ([RFC 9639](https://www.rfc-editor.org/info/rfc9639))

Implemented:
- [x] Metadata
    - [x] Streaminfo
    - [x] Padding
    - [x] Application
    - [x] Seek table
    - [x] Vorbis comment
    - [x] Cuesheet
    - [x] Picture
- [x] Audio Frames
    - [x] Frame Header
        - [x] CRC Checked
    - [x] Subframe
        - [x] Constant 
        - [x] Verbatim
        - [x] Fixed Predictor
        - [x] Linear Predictor
    - [x] Frame Footer
        - [ ] CRC Checked
- [ ] Interchannel Decorrelation
- [ ] MD5 Sum
- [ ] Multithreading

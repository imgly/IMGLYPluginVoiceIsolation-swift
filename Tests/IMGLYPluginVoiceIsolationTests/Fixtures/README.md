# Test fixtures

| File | What it is |
| --- | --- |
| `speech-and-music.flac` | 12.000 s of speech with music, 48 kHz mono 16-bit. |
| `speech-and-music-reference.flac` | Its DeepFilterNet3 output from the upstream `deepfilternet==0.5.6` Python package (`df.enhance.enhance`, default settings), 16-bit. |
| `speech-and-music.m4a` | The first 3 s of `speech-and-music.flac` as AAC, for an audio clip. |
| `speech-and-music-after-silence-reference.flac` | The Python package's output for 100 s of digital silence followed by `speech-and-music.flac`, without the silence, 16-bit. |
| `speech-and-music.mp4` | The same 3 s as the audio track of a black 64 x 64 video, for a video clip. |
| `silent.mp4` | 1 s of a black 64 x 64 video without an audio track, from `ffmpeg -f lavfi -i color=c=black:s=64x64:d=1:r=10 -an`. |
| `speech-and-music-two-tracks.mp4` | `speech-and-music.mp4` with a second, silent AAC track, from `ffmpeg -i speech-and-music.mp4 -f lavfi -t 3 -i anullsrc=r=48000:cl=mono -map 0:v -map 0:a -map 1:a -c:v copy -c:a:0 copy -c:a:1 aac -b:a:1 32k -shortest -map_metadata -1`. |
| `speech-and-music-late-start.m4a` | 2 s of `speech-and-music.m4a` that start at 1 s through an edit list, from `ffmpeg -itsoffset 1 -t 2 -i speech-and-music.m4a -c:a aac -b:a 64k -map_metadata -1`. |
| `speech-and-music-late-audio.mp4` | The video of `speech-and-music.mp4` with 2 s of its audio from 1 s, from `ffmpeg -i speech-and-music.mp4 -itsoffset 1 -t 2 -i speech-and-music.mp4 -map 0:v -map 1:a -c:v copy -c:a aac -b:a 64k -map_metadata -1`. |
| `speech-and-music.webm` | The same 3 s as Opus in WebM. AVFoundation cannot open it, and the engine on iOS cannot open it as a video. |

Rebuild the reference in a Python 3.11 environment with `deepfilternet==0.5.6`, `torch<2.6`, `torchaudio<2.6` and
`soundfile`:

```bash
python make_reference.py speech-and-music.flac speech-and-music-reference.flac
python make_reference.py --leading-silence 100 speech-and-music.flac speech-and-music-after-silence-reference.flac
```

## Sources and licences

The speech is a LibriVox recording of *Cleek of Scotland Yard* by Thomas W. Hanshew, chapter 6, read by Ruth Golding,
445.80 s to 457.80 s of
[cleekofscotlandyard_09_hanshew.mp3](https://archive.org/details/cleek_scotland_yard_rg_librivox),
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

The music is "Where You Are Now" by Alex Beroza (c) copyright 2011, licensed under a Creative Commons Attribution (3.0)
license ([CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)),
[ccMixter](https://ccmixter.org/files/AlexBeroza/33065). Ft: WolfFly. Vocals by Rhiannon Delpero, from the a cappella
"[Rhiannon] Where You Are Now Acapella" uploaded by ascension, CC BY 3.0,
[ccMixter](https://ccmixter.org/files/ascension/27734). Changes: 92.00 s to 104.00 s, mixed to mono, resampled to 48
kHz, normalised to -26 LUFS and mixed with the speech at 0 dB SNR.

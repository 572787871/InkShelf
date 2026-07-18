# InkShelf original ZipVoice reference voices

These three WAV files are original synthetic reference prompts made for
InkShelf. They do not imitate or contain a recording of a real person or a
third-party commercial voice.

- `ink_stable.wav`: eSpeak NG Mandarin voice variant `m3`
- `ink_warm.wav`: eSpeak NG Mandarin voice variant `f2`
- `ink_clear.wav`: eSpeak NG Mandarin voice variant `f4`

All files speak the exact reference transcript used by the app:

`欢迎来到墨架，愿每一个故事，都有属于自己的声音。`

They were generated as mono 16-bit PCM WAV files with eSpeak NG, for example:

```sh
espeak-ng -v cmn+m3 -s 145 -w ink_stable.wav \
  '欢迎来到墨架，愿每一个故事，都有属于自己的声音。'
```

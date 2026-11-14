# murmur-bench

Minimal latency check for the speech model: `murmur-bench file1.aiff file2.wav …` prints model
load time and per-file transcription time. Handy with `say -o clip.aiff "some text"`.
For real measurements use `murmur-eval`.

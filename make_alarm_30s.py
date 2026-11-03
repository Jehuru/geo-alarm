import wave

source = r"assets\sounds\geoalarm_alarm.wav"
output = r"android\app\src\main\res\raw\geoalarm_alarm.wav"

with wave.open(source, "rb") as src:
    params = src.getparams()
    frames = src.readframes(src.getnframes())

    bytes_per_second = params.framerate * params.nchannels * params.sampwidth
    target_bytes = 30 * bytes_per_second

    repeated = (frames * ((target_bytes // len(frames)) + 1))[:target_bytes]

    with wave.open(output, "wb") as dst:
        dst.setparams(params)
        dst.writeframes(repeated)

print("Created 30-second alarm sound.")
print(f"Sample rate: {params.framerate} Hz")
print(f"Channels: {params.nchannels}")
print(f"Sample width: {params.sampwidth} bytes")
print(f"Output size: {len(repeated)} bytes")

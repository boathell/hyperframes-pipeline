#!/usr/bin/env python3
"""
Volcano Engine Seed-TTS WebSocket synthesizer (旧版控制台鉴权).
Usage: python3 doubao_tts.py <text> <output.wav> [speech_rate]
speech_rate: -50~100, 0=normal, positive=faster, negative=slower

Reads credentials and voice list from .env in the same directory as this script.
Falls back to hardcoded values if .env is not found.

.env format:
  APP_ID=3009090267
  APP_TOKEN=xxxxx
  RESOURCE_ID=seed-tts-2.0
  APP_YINSE=voice1,voice2,...
"""
import asyncio, json, os, random, struct, sys, uuid
import websockets

API_URL = "wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream"

# Load .env from script's directory
def _load_env():
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
    env = {}
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, _, v = line.partition('=')
                    env[k.strip()] = v.strip()
    return env

_env   = _load_env()
APPID  = _env.get('APP_ID',      '3009090267')
TOKEN  = _env.get('APP_TOKEN',   '7nrVbOSGR_VYCzMct8L6_4qib583ytQf')
RES_ID = _env.get('RESOURCE_ID', 'seed-tts-2.0')
VOICES = [v for v in _env.get('APP_YINSE', '').split(',') if v] or [
    "zh_female_sophie_uranus_bigtts",
    "zh_female_cancan_uranus_bigtts",
    "zh_female_sajiaoxuemei_uranus_bigtts",
    "zh_female_tianmeixiaoyuan_uranus_bigtts",
    "zh_female_tianmeitaozi_uranus_bigtts",
    "zh_female_yingyujiaoxue_uranus_bigtts",
]
VOICE  = random.choice(VOICES)

EVT_SESSION_DONE = 152

def build_frame(payload_dict):
    data = json.dumps(payload_dict, ensure_ascii=False).encode()
    return b'\x11\x10\x10\x00' + struct.pack('>I', len(data)) + data

async def synth(text: str, out_path: str, speech_rate: int = 0) -> None:
    auth_headers = {
        'X-Api-App-Id':      APPID,
        'X-Api-Access-Key':  TOKEN,
        'X-Api-Resource-Id': RES_ID,
        'X-Api-Request-Id':  str(uuid.uuid4()),
    }
    req_body = {
        'user': {'uid': 'narration_user'},
        'req_params': {
            'text': text,
            'speaker': VOICE,
            'audio_params': {
                'format': 'wav',
                'sample_rate': 24000,
                'speech_rate': speech_rate,
            },
        },
    }

    audio_chunks = []

    async with websockets.connect(
        API_URL, additional_headers=auth_headers, max_size=10**7
    ) as ws:
        await ws.send(build_frame(req_body))

        while True:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=60)
            except asyncio.TimeoutError:
                print('[WARN] recv timeout', file=sys.stderr)
                break
            except websockets.exceptions.ConnectionClosed:
                break

            if not isinstance(raw, bytes) or len(raw) < 4:
                continue

            msg_type = (raw[1] >> 4) & 0xf
            hdr_len  = (raw[0] & 0xf) * 4
            payload  = raw[hdr_len:]

            if len(payload) < 8:
                continue

            event_code = struct.unpack('>I', payload[0:4])[0]
            sid_size   = struct.unpack('>I', payload[4:8])[0]
            # payload: [4B event_code][4B sid_size][sid_size bytes][4B audio_size][audio]
            data_start = 8 + sid_size + 4

            if msg_type == 0xb:          # SERVER_AUDIO_ONLY_RESPONSE
                if len(payload) > data_start:
                    audio_chunks.append(payload[data_start:])

            elif msg_type == 0x9:        # SERVER_FULL_RESPONSE (metadata)
                if event_code == EVT_SESSION_DONE:
                    break

            elif msg_type == 0xf:        # SERVER_ERROR_RESPONSE
                print(f'[ERROR] server error: {payload[:300]}', file=sys.stderr)
                sys.exit(1)

    audio = b''.join(audio_chunks)
    if not audio:
        print('[ERROR] no audio data received', file=sys.stderr)
        sys.exit(1)

    with open(out_path, 'wb') as f:
        f.write(audio)
    print(f'[OK] {out_path}: {len(audio):,} bytes', flush=True)
    print(f'[VOICE] {VOICE}', flush=True)

if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(f'Usage: {sys.argv[0]} <text> <output.wav> [speech_rate]')
    asyncio.run(synth(
        text=sys.argv[1],
        out_path=sys.argv[2],
        speech_rate=int(sys.argv[3]) if len(sys.argv) > 3 else 0,
    ))

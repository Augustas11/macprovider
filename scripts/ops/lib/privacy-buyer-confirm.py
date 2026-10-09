#!/usr/bin/env python3
"""Bounded real-buyer confirmation; never print keys or private response text."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse

# Reviewed reference client source fc9a74459, built on Pearl with Go1.26.6,
# GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 (not a provider/runtime release).
CLIENT_SHA256 = 'fb27294d86deff4051c5fab168bf69a5f457249abfa4cc25d87811ac1e2fad57'


def main():
    if os.environ.get('MACPROVIDER_OPS_ENTRYPOINT') != '1':
        raise ValueError('use the reviewed ops entry point')
    client = Path(os.environ['PRIVACY_BUYER_CLIENT'])
    key = Path(os.environ['BUYER_TOKEN_FILE'])
    pin = Path(os.environ['PRIVACY_BUYER_PIN'])
    directory_key = os.environ['PRIVACY_DIRECTORY_PUBLIC_KEY']
    url = os.environ['GATEWAY_URL']
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ('', '/') or parsed.query or parsed.fragment:
        raise ValueError('GATEWAY_URL must be an HTTPS origin')
    if url != 'https://api.malibu.tech':
        raise ValueError('buyer confirmation is bound to the production gateway')
    for path in (client, key, pin):
        if not path.is_absolute() or not path.is_file():
            raise ValueError('client, key and pin must be absolute existing files')
    if key.stat().st_mode & 0o077:
        raise ValueError('buyer key must be private')
    with client.open('rb') as executable:
        if hashlib.file_digest(executable, 'sha256').hexdigest() != CLIENT_SHA256:
            raise ValueError('client does not match the reviewed reference build')
    env = {'MACPROVIDER_API_KEY': key.read_text().strip()}
    results = []
    for selection in ('pin', 'directory'):
        for stream in (False, True):
            model = 'mlx-community/Qwen3.6-35B-A3B-4bit'
            request = {'model': model, 'max_tokens': 32, 'stream': stream, 'messages': [
                {'role': 'user', 'content': 'Reply with the single word ready.'}]}
            args = [str(client), '--privacy-class', '--base-url', url, '--model', model,
                    '--max-output-tokens', '32', '--input-token-upper-bound', '256', '--timeout', '180s']
            args += ['--identity-pin', str(pin)] if selection == 'pin' else ['--directory-public-key', directory_key]
            if stream:
                args.append('--stream')
            result = subprocess.run(args, input=json.dumps(request), text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=190)
            satisfied = result.returncode == 0 and 'privacy class satisfied;' in result.stderr
            results.append({'selection': selection, 'stream': stream, 'satisfied': satisfied})
            if not satisfied:
                # Fixed classifier only; response bodies and server errors stay
                # private. Failed requests are never retried/downgraded here.
                print(json.dumps({'results': results, 'accepted': False}))
                return 1
    print(json.dumps({'results': results, 'accepted': True,
                      'settlement_confirmation': 'operator receipt check required'}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('buyer confirmation refused: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)

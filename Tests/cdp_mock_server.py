import argparse
import base64
import hashlib
import json
import socket
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--port-file', required=True)
options = parser.parse_args()


class MockCDP(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        port = self.server.server_port
        if self.path == '/json/list':
            data = json.dumps([{'id': 'mock-page', 'type': 'page', 'title': 'Fixture',
                                'url': 'file:///fixture.html',
                                'webSocketDebuggerUrl': f'ws://127.0.0.1:{port}/devtools/page/mock'}]).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path != '/devtools/page/mock' or self.headers.get('Upgrade', '').lower() != 'websocket':
            self.send_error(404)
            return
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        reverse = []
        try:
            while True:
                start = self.rfile.read(2)
                if len(start) != 2:
                    break
                opcode = start[0] & 15
                masked = start[1] & 128
                length = start[1] & 127
                if length == 126:
                    length = struct.unpack('!H', self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack('!Q', self.rfile.read(8))[0]
                mask = self.rfile.read(4) if masked else b''
                payload = self.rfile.read(length)
                if masked:
                    payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
                if opcode == 8:
                    self.frame(8, payload)
                    return
                if opcode == 9:
                    self.frame(10, payload)
                    continue
                if opcode != 1:
                    continue
                request = json.loads(payload)
                method = request['method']
                response = {'id': request['id'], 'result': request.get('params', {})}
                if method == 'Test.silent':
                    continue
                if method == 'Test.protocolError':
                    response = {'id': request['id'], 'error': {'code': -32601, 'message': 'Fixture method failure'}}
                if method == 'Test.runtimeError':
                    response = {'id': request['id'], 'result': {'exceptionDetails': {'text': 'Fixture JavaScript exception'}}}
                if method == 'Test.reverse':
                    reverse.append(response)
                    if len(reverse) == 2:
                        self.send_json({'method': 'Runtime.consoleAPICalled', 'params': {}})
                        for item in reversed(reverse):
                            self.send_json(item)
                        reverse.clear()
                    continue
                if method == 'Test.close':
                    self.frame(8, b'')
                    return
                self.send_json(response)
        except (BrokenPipeError, ConnectionResetError, json.JSONDecodeError):
            return

    def send_json(self, data):
        self.frame(1, json.dumps(data).encode())

    def frame(self, opcode, payload):
        if len(payload) < 126:
            header = bytes([128 | opcode, len(payload)])
        elif len(payload) < 65536:
            header = bytes([128 | opcode, 126]) + struct.pack('!H', len(payload))
        else:
            header = bytes([128 | opcode, 127]) + struct.pack('!Q', len(payload))
        self.wfile.write(header + payload)
        self.wfile.flush()


server = ThreadingHTTPServer(('127.0.0.1', 0), MockCDP)
Path(options.port_file).write_text(str(server.server_port))
print(f'Mock CDP listening on 127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()

#!/usr/bin/env python3
"""验证 deepseek-flash 能不能真的读课表图片。

用途：图片导入功能的前提是「模型能看图」。文档说有原生多模态，
但文档和实际接口是两回事，先用真实 key 打一次。

用法：
    set DS_KEY=sk-xxx
    python tools/vision_probe.py <图片路径>
"""
import base64
import json
import os
import sys
import urllib.request

BASE = os.environ.get('DS_BASE', 'https://api.deepseek.com')
MODEL = os.environ.get('DS_MODEL', 'deepseek-flash')


def main():
    key = os.environ.get('DS_KEY', '')
    if not key:
        sys.exit('缺少 DS_KEY')
    path = sys.argv[1]
    raw = open(path, 'rb').read()
    ext = path.rsplit('.', 1)[-1].lower()
    mime = 'image/png' if ext == 'png' else 'image/jpeg'
    b64 = base64.b64encode(raw).decode()
    print(f'图片 {path}  {len(raw)} 字节  {mime}')

    prompt = (
        '这是一张手机课表截图。请把里面每一节课整理成 JSON 数组，'
        '每项包含 day（1=周一…7=周日）、name（课程名）、periods（节次，'
        '如 "3-4"）、start（HH:mm）、end（HH:mm）、place（地点，没有就 null）。'
        '只输出 JSON，不要解释。看不清的字段留 null，不要猜。'
    )
    body = {
        'model': MODEL,
        'messages': [{
            'role': 'user',
            'content': [
                {'type': 'text', 'text': prompt},
                {'type': 'image_url',
                 'image_url': {'url': f'data:{mime};base64,{b64}'}},
            ],
        }],
        'temperature': 0,
    }
    req = urllib.request.Request(
        BASE.rstrip('/') + '/chat/completions',
        data=json.dumps(body).encode(),
        headers={'Authorization': 'Bearer ' + key,
                 'Content-Type': 'application/json'},
    )
    try:
        resp = json.load(urllib.request.urlopen(req, timeout=180))
    except urllib.error.HTTPError as e:
        print('HTTP', e.code)
        print(e.read().decode('utf-8', 'ignore')[:800])
        sys.exit(1)
    text = resp['choices'][0]['message']['content']
    print('--- 模型返回 ---')
    print(text[:2500])
    usage = resp.get('usage', {})
    print('--- 用量 ---', json.dumps(usage, ensure_ascii=False))


if __name__ == '__main__':
    main()

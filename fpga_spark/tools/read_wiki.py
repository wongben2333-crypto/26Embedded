import re
import sys
import os

sys.stdout.reconfigure(encoding='utf-8')

p60k = r'C:\Users\gjl50\.gemini\antigravity\brain\3821e740-60f7-42a1-9a08-34e065ec2d75\.system_generated\steps\399\content.md'
p138k = r'C:\Users\gjl50\.gemini\antigravity\brain\3821e740-60f7-42a1-9a08-34e065ec2d75\.system_generated\steps\401\content.md'

def get_article(path):
    with open(path, 'r', encoding='utf-8') as f:
        html = f.read()
    m = re.search(r'<div id="article_content"[^>]*>(.*?)</div>\s*<div id="previous_next">', html, re.DOTALL)
    if not m:
        m = re.search(r'<div id="article_content"[^>]*>(.*?)<div id="comments', html, re.DOTALL)
    if m:
        text = m.group(1)
        text = re.sub(r'<style.*?</style>', '', text, flags=re.DOTALL)
        text = re.sub(r'<script.*?</script>', '', text, flags=re.DOTALL)
        # convert tables to readable lines
        text = re.sub(r'</tr>', '\n', text)
        text = re.sub(r'</td>', ' | ', text)
        text = re.sub(r'</th>', ' | ', text)
        text = re.sub(r'<h[1-6][^>]*>', '\n### ', text)
        text = re.sub(r'</h[1-6]>', '\n', text)
        text = re.sub(r'<li[^>]*>', '\n* ', text)
        text = re.sub(r'<p[^>]*>', '\n', text)
        text = re.sub(r'<br\s*/?>', '\n', text)
        text = re.sub(r'<[^>]+>', '', text)
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        return '\n'.join(lines)
    return "Not found"

print("==================== TANG MEGA 60K ====================")
art60 = get_article(p60k)
print(art60[:4000])

print("\n==================== TANG MEGA 138K ====================")
art138 = get_article(p138k)
print(art138[:4000])

"""Generate a publishable cask only after a real release archive exists."""
import argparse
import hashlib
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--version', required=True)
parser.add_argument('--repository', default='quocfe/paste-clip')
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
    parser.error('Version must be MAJOR.MINOR.PATCH')
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
    parser.error('Repository must be owner/name')
if not args.archive.is_file():
    parser.error('Release archive does not exist')
digest = hashlib.sha256(args.archive.read_bytes()).hexdigest()
text = f'''cask "clipstack" do
  version "{args.version}"
  sha256 "{digest}"

  url "https://github.com/{args.repository}/releases/download/v#{{version}}/ClipStack-#{{version}}.zip"
  name "ClipStack"
  desc "Fast local-first clipboard manager for macOS"
  homepage "https://github.com/{args.repository}"

  depends_on macos: ">= :ventura"
  app "ClipStack.app"

  zap trash: [
    "~/Library/Application Support/ClipStack",
    "~/Library/Preferences/com.quocfe.ClipStack.plist",
  ]
end
'''
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(text, encoding='utf-8')
print(f'Generated {args.output} with SHA256 {digest}')

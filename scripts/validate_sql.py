"""Portable checks against the actual migration and cleanup SQL in the Swift source.

These complement, and do not replace, the macOS Swift/AppKit tests.
"""
from pathlib import Path
import re
import sqlite3
import time
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'Sources/ClipStackCore/ClipboardRepository.swift').read_text(encoding='utf-8')
MIGRATION = re.search(r'db\.execute\(\s*sql: """\n(.*?)\n\s*"""\)', SOURCE, re.S).group(1)
CAP_SQL = re.search(r'db\.execute\(\s*sql:\s*"(DELETE FROM clipboard_items WHERE id IN.*?)",\s*arguments:', SOURCE).group(1)

class DatabaseInvariants(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript(MIGRATION)

    def tearDown(self):
        self.db.close()

    def insert(self, id, text, stamp='2026-09-01 12:00:00', pin=False):
        self.db.execute('INSERT INTO clipboard_items (id,type,plainText,contentHash,sourceAppName,createdAt,updatedAt,isFavorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                        (str(id), 'text', text, str(id), 'Terminal', stamp, stamp, pin))

    def search(self, pattern):
        return self.db.execute('SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?', (pattern,)).fetchall()

    def test_fts_insert_update_delete(self):
        self.insert(1, 'docker compose up -d')
        self.assertEqual(len(self.search('"dock"* AND "comp"*')), 1)
        self.assertEqual(len(self.search('"terminal"*')), 1)
        self.db.execute("UPDATE clipboard_items SET plainText='npm run dev' WHERE id='1'")
        self.assertEqual(self.search('docker'), [])
        self.assertEqual(len(self.search('npm')), 1)
        self.db.execute("DELETE FROM clipboard_items WHERE id='1'")
        self.assertEqual(self.search('npm'), [])

    def test_uniqueness(self):
        self.insert(1, 'hello')
        with self.assertRaises(sqlite3.IntegrityError):
            self.insert(1, 'hello again')

    def test_cap_includes_pins(self):
        self.insert(1, 'old', '2026-01-01 00:00:00')
        self.insert(2, 'pinned', '2026-01-01 00:00:00', True)
        for i in range(3, 10):
            self.insert(i, f'clip {i}', f'2026-09-0{i} 00:00:00')
        self.db.execute(CAP_SQL, (2,))
        ids = {row[0] for row in self.db.execute('SELECT id FROM clipboard_items')}
        self.assertEqual(ids, {'8', '9'})
        self.assertEqual(self.search('old'), [])

    def test_search_at_50000_clips(self):
        for i in range(50000):
            self.insert(i, f'docker compose project{i}')
        started = time.perf_counter()
        rows = self.search('"project49999"*')
        elapsed = time.perf_counter() - started
        self.assertEqual(len(rows), 1)
        plan = self.db.execute('EXPLAIN QUERY PLAN SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?', ('project49999',)).fetchall()
        self.assertTrue(any('VIRTUAL TABLE INDEX' in row[-1] for row in plan))
        print(f'\n50,000-clip FTS lookup: {elapsed * 1000:.2f} ms (local SQLite only)')

if __name__ == '__main__':
    unittest.main(verbosity=2)

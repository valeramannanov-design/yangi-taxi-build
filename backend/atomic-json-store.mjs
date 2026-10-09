import crypto from 'node:crypto';
import { mkdir, writeFile, rename, unlink } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Serialize in-process writes and atomically replace the destination on success.
// A failed write rejects that caller, but does not poison later saves.
export function createAtomicJsonWriter(fileUrl) {
  const file = fileURLToPath(fileUrl);
  let writes = Promise.resolve();
  return function writeJson(value) {
    const snapshot = JSON.stringify(value, null, 2);
    writes = writes.catch(() => {}).then(async () => {
      const directory = dirname(file);
      await mkdir(directory, { recursive: true });
      const temp = join(directory, '.' + basename(file) + '.' + process.pid + '.' + crypto.randomUUID() + '.tmp');
      try {
        await writeFile(temp, snapshot, { encoding: 'utf8', mode: 0o600 });
        await rename(temp, file);
      } finally {
        await unlink(temp).catch((e) => {
          if (e.code !== 'ENOENT') throw e;
        });
      }
    });
    return writes;
  };
}

import { spawn } from 'child_process';
import path from 'path';

/**
 * Opens the file in the user's preferred editor and waits for them to close it.
 * Checks $VISUAL, $EDITOR, then falls back to platform defaults.
 */
export async function editInExternalEditor(filePath: string): Promise<void> {
  const { cmd, args } = getEditor();
  const absolutePath = path.resolve(filePath);

  return new Promise((resolve, reject) => {
    const child = spawn(cmd, [...args, absolutePath], {
      stdio: 'inherit',
      shell: true,
    });

    child.on('error', (err) => {
      reject(new Error(`Failed to open editor: ${err.message}`));
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Editor exited with code ${code}`));
      }
    });
  });
}

/**
 * Get the editor/opener command to use.
 * Priority: $VISUAL > $EDITOR > platform default (opens with associated app)
 */
function getEditor(): { cmd: string; args: string[] } {
  if (process.env.VISUAL) return { cmd: process.env.VISUAL, args: [] };
  if (process.env.EDITOR) return { cmd: process.env.EDITOR, args: [] };

  // Platform defaults - open with associated application
  if (process.platform === 'win32') {
    // 'start' opens with default app, '' is window title, /wait makes it blocking
    return { cmd: 'start', args: ['""', '/wait'] };
  }
  if (process.platform === 'darwin') {
    // macOS: open -W waits for app to close
    return { cmd: 'open', args: ['-W'] };
  }
  // Linux: xdg-open (doesn't wait, but best we can do)
  return { cmd: 'xdg-open', args: [] };
}

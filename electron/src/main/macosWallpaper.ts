import type { ChildProcessWithoutNullStreams } from 'node:child_process'

export function startNativeWallpaper(
  child: ChildProcessWithoutNullStreams,
  onUnexpectedExit: () => void,
) {
  let state: 'starting' | 'ready' | 'stopped' = 'starting'
  let settle!: (ready: boolean) => void
  const ready = new Promise<boolean>(resolve => { settle = resolve })
  const stop = () => {
    if (state === 'stopped') return
    state = 'stopped'
    clearTimeout(timeout)
    settle(false)
    child.stdin.end()
    child.kill()
  }
  const timeout = setTimeout(stop, 8000)
  let line = ''
  child.stdout.setEncoding('utf8').on('data', (chunk: string) => {
    if (state === 'stopped') return
    const lines = (line + chunk).split('\n')
    line = (lines.pop() ?? '').slice(-256)
    for (const entry of lines) {
      if (state === 'starting' && entry === 'ready') {
        state = 'ready'
        clearTimeout(timeout)
        settle(true)
      } else if (entry.startsWith('[native-wallpaper] ')) {
        console.info(entry)
      }
    }
  })
  child.stderr.setEncoding('utf8').on('data', (chunk: string) => {
    console.error(chunk.trimEnd())
  })
  child.stdin.on('error', () => { /* The child can close stdin while exiting. */ })
  const exited = () => {
    const recover = state === 'ready'
    state = 'stopped'
    clearTimeout(timeout)
    settle(false)
    if (recover) onUnexpectedExit()
  }
  child.once('error', (error) => {
    console.error('[native-wallpaper] start failed:', error.message)
    exited()
  })
  child.once('exit', exited)
  return { ready, stop }
}

// Spawn fixtures execute the emitted startup extension with Pi's event interface.
// The real-harness guard owns proof that Pi actually emits this event.
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
const launch = process.argv[2];
const token = path.basename(launch).replace(/^launch\./, '').replace(/\.sh$/, '');
const extension = path.join(path.dirname(launch), `pi-start.${token}.ts`);
if (existsSync(extension)) {
  const events = new Map();
  const module = await import('data:text/javascript;base64,' + Buffer.from(readFileSync(extension)).toString('base64'));
  module.default({on: (name, callback) => events.set(name, callback)});
  const prompt = readFileSync(path.join(path.dirname(launch), `pi-start.${token}.prompt`), 'utf8').replace(/\n+$/, '');
  await events.get('before_agent_start')?.({prompt});
  await events.get('agent_start')?.();
}

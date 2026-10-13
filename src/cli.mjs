import { doctor } from './doctor.mjs';
import { safeError } from './util.mjs';

if (process.argv[2] !== 'doctor') {
  process.stderr.write('Usage: node src/cli.mjs doctor\n');
  process.exitCode = 2;
} else {
  try {
    const result = await doctor();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exitCode = result.ok ? 0 : 1;
  } catch (error) {
    process.stderr.write(`${safeError(error)}\n`);
    process.exitCode = 1;
  }
}

// cua-rdp ZCode panel: starts and connects the RDP Child Session through the plugin's own
// MCP server, and shows how the session agent takes the same desktop over with the
// desktop_* tools. The panel and the agent share one server process, so a desktop started
// here is exactly the one the agent operates, and vice versa.
import { App } from '@modelcontextprotocol/ext-apps';

const app = new App({ name: 'cua-rdp-panel', version: '0.4.6' }, {});
let inFlight = null;
let refreshTimer = 0;

// Register handlers before connect so nothing is lost while the page loads.
app.ontoolresult = () => scheduleRefresh(200);
app.onhostcontextchanged = () => applyTheme();

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const container = document.getElementById('panel');
const statusBadge = element('div', 'badge state-unknown', '…');
const detailList = element('dl', 'details');
const errorBox = element('div', 'error hidden');
const noticeBox = element('div', 'notice hidden');
const takeoverBox = element('div', 'takeover hidden');
const startButton = element('button', 'primary', '启动（后台）');
const interactiveButton = element('button', '', '交互式启动…');
const stopButton = element('button', 'danger', '停止');
const buttonRow = element('div', 'actions');

function applyTheme() {
  document.documentElement.dataset.theme = app.getHostContext()?.theme === 'dark' ? 'dark' : 'light';
}

function scheduleRefresh(delay = 0) {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => { refresh().catch(() => {}); }, delay);
}

function resultJson(result) {
  const text = result?.content?.find(part => part.type === 'text')?.text;
  if (typeof text !== 'string') return null;
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' ? value : null;
  }
  catch { return null; }
}

function render(value) {
  const state = typeof value.state === 'string' ? value.state : 'unknown';
  statusBadge.textContent = state;
  statusBadge.dataset.state = state;
  detailList.replaceChildren();
  for (const [label, key] of [['后端', 'backend'], ['子会话', 'sessionId'], ['父会话', 'parentSessionId'], ['运行', 'runId'], ['隔离', 'isolation']]) {
    if (value[key] === undefined || value[key] === null) continue;
    detailList.append(element('dt', '', label), element('dd', '', String(value[key])));
  }
  const error = typeof value.error === 'string' ? value.error : '';
  const code = typeof value.code === 'string' ? value.code : '';
  errorBox.classList.toggle('hidden', !error);
  errorBox.replaceChildren();
  if (error) {
    errorBox.append(element('div', '', error));
    if (code === 'AUTHENTICATION_REQUIRED') {
      errorBox.append(element('div', 'hint', '此系统要求每次连接输入 Windows 密码。点击“交互式启动…”，在弹出的 Windows 窗口中输入密码；密码不会进入对话或本面板。'));
    }
  }
  takeoverBox.classList.toggle('hidden', state !== 'ready');
  const stopped = ['stopped', 'needs-authentication', 'failed'].includes(state) || state === 'unknown';
  const running = !stopped;
  startButton.disabled = running || inFlight !== null;
  interactiveButton.disabled = running || inFlight !== null;
  stopButton.disabled = stopped || inFlight !== null;
}

function notice(text) {
  noticeBox.classList.toggle('hidden', !text);
  noticeBox.textContent = text ?? '';
}

async function refresh() {
  if (inFlight) return;
  const result = await app.callServerTool({ name: 'desktop_status', arguments: {} });
  const value = resultJson(result);
  if (value) render(value);
}

async function run(label, arguments_) {
  if (inFlight) return;
  inFlight = label;
  startButton.disabled = true;
  interactiveButton.disabled = true;
  stopButton.disabled = true;
  notice(label === 'stop' ? '正在停止本控制器的连接…'
    : label === 'interactive' ? '等待 Windows 登录窗口（最长约 330 秒）：请在弹出的窗口中输入密码，密码不会进入对话或本面板。'
      : '正在后台建立子会话…');
  try {
    const result = await app.callServerTool({ name: label === 'stop' ? 'desktop_stop' : 'desktop_start', arguments: arguments_ });
    const value = resultJson(result);
    if (value) render(value);
    else notice('服务器返回了无法解析的结果。');
  }
  catch (error) {
    errorBox.classList.remove('hidden');
    errorBox.replaceChildren(element('div', '', String(error?.message ?? error)));
  }
  finally {
    inFlight = null;
    notice('');
    scheduleRefresh();
  }
}

startButton.addEventListener('click', () => { run('start', {}).catch(() => {}); });
interactiveButton.addEventListener('click', () => { run('interactive', { authentication: 'interactive' }).catch(() => {}); });
stopButton.addEventListener('click', () => { run('stop', {}).catch(() => {}); });

container.append(
  element('h1', '', '子桌面'),
  element('p', 'subtitle', 'RDP 子会话中的隔离 Windows 桌面（cua-rdp）'),
  statusBadge,
  detailList,
  errorBox,
  noticeBox,
  buttonRow,
  takeoverBox,
  element('p', 'footnote', '最小化/关闭看护窗口会安全停靠；desktop_stop 结束连接，但不会注销子会话。'),
);
buttonRow.append(startButton, interactiveButton, stopButton);
takeoverBox.append(
  element('h2', '', '会话接管'),
  element('p', '', '本会话的 agent 已可通过 desktop_* 工具操作这块桌面（desktop_status / desktop_call 等）。直接在对话中布置任务即可，例如：'),
  element('pre', 'example', '使用 CUA RDP 子桌面打开记事本，输入 child desktop takeover，读回验证后停止。'),
);

applyTheme();
void (async () => {
  try {
    await app.connect();
    await refresh();
  }
  catch (error) {
    errorBox.classList.remove('hidden');
    errorBox.replaceChildren(element('div', '', `面板连接失败：${String(error?.message ?? error)}`));
  }
})();

/* grid-repair :: fuse widget (PLACEHOLDER logic)
 *
 * TODO(nui-developer): replace this stub with the real fuse-sequence minigame.
 * This version only:
 *   - shows/hides a corner panel on the start/end messages,
 *   - runs the countdown bar and auto-reports a timeout failure,
 *   - lets the player press the shown digits (or Esc to cancel),
 * so the Lua stage can be QA'd end-to-end without a focus soft-lock.
 *
 * Contract (see client/main.lua "NUI CONTRACT"):
 *   IN  { action:'startFuseGame', sequence:[int], fuseCount:int, timeLimit:int }
 *   IN  { action:'endFuseGame' }
 *   OUT fuseResult { success:bool, entered:[int] }
 *   OUT fuseCancel {}
 */

const widget = document.getElementById('fuse-widget');
const seqEl = document.getElementById('seq');
const barEl = document.getElementById('timer-bar');

let state = null; // { sequence, entered, deadline, timer }

// Resource name is injected by CEF as GetParentResourceName(); fall back safely.
function resName() {
    return (typeof GetParentResourceName === 'function')
        ? GetParentResourceName()
        : 'grid-repair';
}

function post(name, body) {
    fetch(`https://${resName()}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body || {}),
    }).catch(() => {});
}

function close() {
    if (state && state.timer) clearInterval(state.timer);
    state = null;
    widget.classList.add('hidden');
}

function start(data) {
    state = {
        sequence: data.sequence || [],
        entered: [],
        deadline: Date.now() + (data.timeLimit || 12000),
        limit: data.timeLimit || 12000,
        timer: null,
    };

    // Placeholder view: reveal the target sequence so a tester can type it.
    seqEl.textContent = state.sequence.join(' ');
    widget.classList.remove('hidden');

    state.timer = setInterval(() => {
        const left = state.deadline - Date.now();
        const pct = Math.max(0, (left / state.limit) * 100);
        barEl.style.width = pct + '%';
        if (left <= 0) {
            post('fuseResult', { success: false, entered: [] }); // timeout
            close();
        }
    }, 50);
}

// Placeholder input: number keys append to the entered sequence; Enter submits;
// Esc cancels. The real widget will use clickable fuse buttons instead.
document.addEventListener('keydown', (e) => {
    if (!state) return;

    if (e.key === 'Escape') {
        post('fuseCancel', {});
        close();
        return;
    }
    if (e.key === 'Enter') {
        const ok = state.entered.length === state.sequence.length
            && state.entered.every((v, i) => v === state.sequence[i]);
        post('fuseResult', { success: ok, entered: state.entered });
        close();
        return;
    }
    const n = parseInt(e.key, 10);
    if (!Number.isNaN(n)) {
        state.entered.push(n);
        seqEl.textContent = `${state.sequence.join(' ')}   [${state.entered.join(' ')}]`;
    }
});

window.addEventListener('message', (ev) => {
    const data = ev.data || {};
    if (data.action === 'startFuseGame') start(data);
    else if (data.action === 'endFuseGame') close();
});

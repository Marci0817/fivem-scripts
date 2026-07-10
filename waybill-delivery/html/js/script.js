// Waybill Delivery NUI Widget
// Focusless display-only widget - never calls SetNuiFocus

// State
let currentWaybill = null;
let timeInterval = null;
let previousItemsHash = null;  // track items to avoid unnecessary rebuilds

// Status label mapping
const statusLabels = {
    assigned: 'Assigned',
    packed: 'Packing',
    loaded: 'In Transit',
    delivered: 'Delivered',
    confirmed: 'Confirmed'
};

// Initialize
document.addEventListener('DOMContentLoaded', function() {
    console.log('[waybill-delivery] NUI widget initialized');
});

// Listen for SendNUIMessage from Lua
window.addEventListener('message', function(event) {
    const data = event.data;

    if (data.type !== 'waybillDisplay') {
        return;
    }

    if (!data.visible) {
        hideWidget();
        return;
    }

    // Update widget with new waybill data
    currentWaybill = data.waybill;
    renderWaybill();
    showWidget();
});

/**
 * Show the widget and start the time ticker
 */
function showWidget() {
    const widget = document.getElementById('waybillWidget');
    widget.classList.remove('hidden');

    // Start time countdown if not already running
    if (!timeInterval) {
        timeInterval = setInterval(function() {
            if (currentWaybill) {
                // Decrement time
                currentWaybill.timeRemaining = Math.max(0, currentWaybill.timeRemaining - 1);
                updateTimeDisplay();
            }
        }, 1000);
    }
}

/**
 * Hide the widget and stop the time ticker
 */
function hideWidget() {
    const widget = document.getElementById('waybillWidget');
    widget.classList.add('hidden');

    if (timeInterval) {
        clearInterval(timeInterval);
        timeInterval = null;
    }

    currentWaybill = null;
    previousItemsHash = null;  // reset hash on hide
}

/**
 * Generate a simple hash of items for change detection
 */
function hashItems() {
    if (!currentWaybill || !currentWaybill.items) return null;
    return currentWaybill.items.map(it => `${it.label}:${it.packed}:${it.qty}`).join('|');
}

/**
 * Render the complete waybill
 */
function renderWaybill() {
    if (!currentWaybill) return;

    // Client name
    document.getElementById('clientName').textContent = currentWaybill.clientName || 'Unknown Client';

    // Destination
    document.getElementById('destination').textContent = currentWaybill.destination?.label || 'Unknown Destination';

    // Items list — only rebuild if items actually changed
    const itemsHash = hashItems();
    if (itemsHash !== previousItemsHash) {
        renderItems();
        previousItemsHash = itemsHash;
    }

    // Time display
    updateTimeDisplay();

    // Payout
    document.getElementById('payout').textContent = `$${currentWaybill.basePayout}`;

    // Status badge
    renderStatusBadge();
}

/**
 * Render items checklist
 */
function renderItems() {
    const itemsList = document.getElementById('itemsList');
    itemsList.innerHTML = '';

    if (!currentWaybill.items || currentWaybill.items.length === 0) {
        const emptyRow = document.createElement('div');
        emptyRow.className = 'item-row';
        emptyRow.textContent = 'No items';
        itemsList.appendChild(emptyRow);
        return;
    }

    currentWaybill.items.forEach(item => {
        const isPacked = item.packed === item.qty;
        const isPartial = item.packed > 0 && item.packed < item.qty;

        const itemRow = document.createElement('div');
        itemRow.className = 'item-row';
        if (isPacked) {
            itemRow.classList.add('packed');
        } else if (isPartial) {
            itemRow.classList.add('partial');
        }

        // Label
        const label = document.createElement('span');
        label.className = 'item-label';
        label.textContent = item.label;

        // Progress section
        const progress = document.createElement('div');
        progress.className = 'item-progress';

        // Count display
        const count = document.createElement('span');
        count.className = 'item-count';
        count.textContent = `${item.packed}/${item.qty}`;

        // Badge with checkmark or indicator
        const badge = document.createElement('span');
        badge.className = 'item-badge';
        if (isPacked) {
            badge.textContent = '✓';
        } else {
            badge.classList.add('partial');
            badge.textContent = Math.round((item.packed / item.qty) * 100) + '%';
        }

        progress.appendChild(count);
        progress.appendChild(badge);

        itemRow.appendChild(label);
        itemRow.appendChild(progress);

        itemsList.appendChild(itemRow);
    });
}

/**
 * Update time display and apply warning color if < 2 minutes
 */
function updateTimeDisplay() {
    const timeElement = document.getElementById('timeRemaining');
    const minutes = Math.floor(currentWaybill.timeRemaining / 60);
    const seconds = currentWaybill.timeRemaining % 60;
    const timeStr = `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;

    timeElement.textContent = timeStr;

    // Warning color if less than 2 minutes
    if (currentWaybill.timeRemaining < 120) {
        timeElement.classList.add('warning');
    } else {
        timeElement.classList.remove('warning');
    }
}

/**
 * Render status badge with human-readable label
 */
function renderStatusBadge() {
    const badge = document.getElementById('statusBadge');
    const status = currentWaybill.status || 'assigned';
    const label = statusLabels[status] || status;

    badge.textContent = label;

    // Remove all status classes
    badge.classList.remove('packing', 'loaded', 'in-transit', 'delivered', 'confirmed');

    // Add appropriate status class
    if (status === 'packed') {
        badge.classList.add('packing');
    } else if (status === 'loaded') {
        badge.classList.add('loaded', 'in-transit');
    } else if (status === 'delivered') {
        badge.classList.add('delivered');
    } else if (status === 'confirmed') {
        badge.classList.add('confirmed');
    }
}

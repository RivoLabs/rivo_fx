// The page side: @rivolabs/fx-nui gives typed calls into client.lua.
import { fetchNui, onMessage, isNuiError, mockNui } from './fx-nui.js'

const shop = document.getElementById('shop')
const items = document.getElementById('items')
const status = document.getElementById('status')
const qty = document.getElementById('qty')

const setStatus = (text) => { status.textContent = text }

const buy = async (item) => {
  try {
    const r = await fetchNui('buy', { item, qty: Number(qty.value) })
    setStatus(`Bought ${r.qty}x ${r.item} for $${r.paid}. $${r.cash} cash left.`)
  } catch (e) {
    if (isNuiError(e, 'InsufficientFunds')) setStatus(`Not enough cash: need $${e.fields.need}, have $${e.fields.have}.`)
    else if (isNuiError(e, 'NuiInvalidInput')) setStatus(`Check the order: ${e.fields.message}`)
    else setStatus(`Something went wrong (${e._tag ?? e}).`)
  }
}

onMessage('open', ({ items: list }) => {
  items.replaceChildren(...list.map((name) => {
    const b = document.createElement('button')
    b.textContent = name
    b.onclick = () => buy(name)
    return b
  }))
  setStatus('')
  shop.classList.add('open')
})

window.addEventListener('message', (e) => {
  if (e.data?.type === 'close') shop.classList.remove('open')
})

const close = () => fetchNui('close', {})
document.getElementById('close').onclick = close
window.addEventListener('keydown', (e) => { if (e.key === 'Escape') close() })

// Outside the game (opening index.html in a browser), answer calls locally.
mockNui('buy', ({ item, qty }) => ({ item, qty, paid: qty * 5, cash: 100 - qty * 5 }))
mockNui('close', () => true)

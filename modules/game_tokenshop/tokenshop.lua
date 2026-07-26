-- Tokens Shop :: AstraClient module
-- modules/game_tokenshop/tokenshop.lua
--
-- Le o opcode nativo 0x57 e responde no 0x56. Categorias, ofertas, precos e
-- descricoes vem TODOS do servidor; nada de catalogo hardcoded aqui.

tokenShopWindow = nil

local OPCODE_SERVER = 0x57
local OPCODE_CLIENT = 0x56

local S2C_CATALOG = 0x00
local S2C_BALANCE = 0x01
local S2C_RESULT = 0x02

local C2S_REQUEST_CATALOG = 0x00
local C2S_BUY = 0x01

local RESULT_MESSAGES = {
	[1] = 'This offer no longer exists.',
	[2] = 'You do not have enough tokens.',
	[3] = 'Not enough room or capacity.',
	[4] = 'Invalid amount.',
}

local shops = {}
local shopOrder = {}
local categories = {}
local offers = {}
local offersByCategory = {}
local categoriesByShop = {}
local categoryRows = {}
local offerSlots = {}

local selectedShop = nil
local selectedCategory = nil
local selectedOffer = nil
local balances = {}

-- ============================================================
-- ENVIO
-- ============================================================

local function send(action, offerId, count)
	local protocolGame = g_game.getProtocolGame()
	if not protocolGame then
		return false
	end

	local msg = OutputMessage.create()
	msg:addU8(OPCODE_CLIENT)
	msg:addU8(action)
	if offerId then
		msg:addU16(offerId)
		msg:addU16(count or 1)
	end
	protocolGame:send(msg)
	return true
end

function requestCatalog()
	send(C2S_REQUEST_CATALOG)
end

-- ============================================================
-- LEITURA
-- ============================================================

local function parseCatalog(msg)
	local parsedShops = {}
	local parsedBalances = {}
	local shopCount = msg:getU8()
	for _ = 1, shopCount do
		local shop = {
			id = msg:getU8(),
			name = msg:getString(),
			currencyClientId = msg:getU16(),
			currencyName = msg:getString(),
		}
		parsedBalances[shop.id] = msg:getU32()
		parsedShops[#parsedShops + 1] = shop
	end

	local parsedCategories = {}
	local categoryCount = msg:getU8()
	for _ = 1, categoryCount do
		parsedCategories[#parsedCategories + 1] = {
			id = msg:getU8(),
			shop = msg:getU8(),
			clientId = msg:getU16(),
			name = msg:getString(),
		}
	end

	local parsedOffers = {}
	local offerCount = msg:getU16()
	for _ = 1, offerCount do
		parsedOffers[#parsedOffers + 1] = {
			id = msg:getU16(),
			category = msg:getU8(),
			clientId = msg:getU16(),
			name = msg:getString(),
			price = msg:getU32(),
			stackable = msg:getU8() ~= 0,
			description = msg:getString(),
		}
	end

	return parsedShops, parsedCategories, parsedOffers, parsedBalances
end

-- ============================================================
-- RENDER
-- ============================================================

local function currentBalance()
	return balances[selectedShop] or 0
end

local function refreshBalance()
	if not tokenShopWindow then
		return
	end

	local shop = shops[selectedShop]
	if not shop then
		return
	end

	tokenShopWindow:recursiveGetChildById('shopBalance')
		:setText(tr('%s: %s', shop.currencyName, comma_value(currentBalance())))

	tokenShopWindow:recursiveGetChildById('balanceLabel')
		:setText(tr('Shop %d of %d', selectedShop, #shopOrder))
end

local function refreshTotal()
	if not tokenShopWindow then
		return
	end

	local totalLabel = tokenShopWindow:recursiveGetChildById('totalLabel')
	if not selectedOffer then
		totalLabel:setText('')
		return
	end

	local countBox = tokenShopWindow:recursiveGetChildById('countBox')
	local count = countBox:getValue()
	local total = selectedOffer.price * count
	local available = currentBalance()

	totalLabel:setText(tr('Total: %s', comma_value(total)))
	totalLabel:setColor(total > available and '#d40d06' or '#f0c040')

	tokenShopWindow:recursiveGetChildById('buyButton'):setEnabled(total <= available)
end

local function renderDetail()
	if not tokenShopWindow then
		return
	end

	local nameLabel = tokenShopWindow:recursiveGetChildById('detailName')
	local descLabel = tokenShopWindow:recursiveGetChildById('detailDescription')
	local countBox = tokenShopWindow:recursiveGetChildById('countBox')
	local buyButton = tokenShopWindow:recursiveGetChildById('buyButton')

	if not selectedOffer then
		nameLabel:setText('')
		descLabel:setText(tr('Select an item to see its details.'))
		countBox:setEnabled(false)
		countBox:setValue(1)
		buyButton:setEnabled(false)
		tokenShopWindow:recursiveGetChildById('totalLabel'):setText('')
		return
	end

	nameLabel:setText(selectedOffer.name)
	descLabel:setText(selectedOffer.description)

	-- Quantidade liberada para qualquer item: o servidor entrega N unidades
	-- mesmo em item nao stackable (allowMultipleNonStackable).
	countBox:setEnabled(true)

	refreshTotal()
end

function selectOffer(offerId)
	selectedOffer = offers[offerId]

	for id, slot in pairs(offerSlots) do
		slot:setChecked(id == offerId)
	end

	renderDetail()
end

local function renderOffers()
	local panel = tokenShopWindow:recursiveGetChildById('offerPanel')
	panel:destroyChildren()
	offerSlots = {}

	local list = offersByCategory[selectedCategory] or {}

	for _, offer in ipairs(list) do
		local slot = g_ui.createWidget('TokenOfferSlot', panel)
		slot.offerId = offer.id

		local item = slot:getChildById('item')
		if offer.clientId > 0 then
			item:setItemId(offer.clientId)
		end

		slot:getChildById('caption'):setText(offer.name)
		slot:getChildById('price'):setText(comma_value(offer.price))
		slot:setTooltip(offer.name .. '\n\n' .. offer.description)

		slot.onClick = function(widget)
			selectOffer(widget.offerId)
		end

		offerSlots[offer.id] = slot
	end

	selectedOffer = nil
	renderDetail()
end

function selectCategory(categoryId)
	selectedCategory = categoryId

	for id, row in pairs(categoryRows) do
		row:setChecked(id == categoryId)
	end

	renderOffers()
end

local function rebuildCategories()
	local list = tokenShopWindow:recursiveGetChildById('categoryList')
	list:destroyChildren()
	categoryRows = {}

	for _, category in ipairs(categoriesByShop[selectedShop] or {}) do
		local row = g_ui.createWidget('TokenCategoryButton', list)
		row.categoryId = category.id

		local icon = row:getChildById('icon')
		if category.clientId > 0 then
			icon:setItemId(category.clientId)
		end

		local count = #(offersByCategory[category.id] or {})
		row:getChildById('title'):setText(tr('%s (%d)', category.name, count))

		row.onClick = function(widget)
			selectCategory(widget.categoryId)
		end

		categoryRows[category.id] = row
	end
end

-- Troca de loja: recarrega cabecalho, categorias e ofertas.
function selectShop(shopId)
	local shop = shops[shopId]
	if not shop then
		return
	end

	selectedShop = shopId

	local icon = tokenShopWindow:recursiveGetChildById('shopCurrencyIcon')
	if shop.currencyClientId > 0 then
		icon:setItemId(shop.currencyClientId)
	end

	tokenShopWindow:recursiveGetChildById('shopTitle'):setText(shop.name)

	rebuildCategories()
	refreshBalance()

	local first = (categoriesByShop[shopId] or {})[1]
	if first then
		selectCategory(first.id)
	else
		selectedCategory = nil
		selectedOffer = nil
		tokenShopWindow:recursiveGetChildById('offerPanel'):destroyChildren()
		offerSlots = {}
		renderDetail()
	end
end

-- Navegacao circular pelas setas.
local function cycleShop(step)
	if #shopOrder == 0 then
		return
	end

	local index = 1
	for position, shopId in ipairs(shopOrder) do
		if shopId == selectedShop then
			index = position
			break
		end
	end

	index = ((index - 1 + step) % #shopOrder) + 1
	selectShop(shopOrder[index])
end

function nextShop()
	cycleShop(1)
end

function previousShop()
	cycleShop(-1)
end

-- ============================================================
-- HANDLERS DE PACOTE
-- ============================================================

local function onCatalog(msg)
	local parsedShops, parsedCategories, parsedOffers, parsedBalances = parseCatalog(msg)

	shops = {}
	shopOrder = {}
	for _, shop in ipairs(parsedShops) do
		shops[shop.id] = shop
		shopOrder[#shopOrder + 1] = shop.id
	end

	categories = parsedCategories
	offers = {}
	offersByCategory = {}
	categoriesByShop = {}

	for _, category in ipairs(categories) do
		offersByCategory[category.id] = {}
		categoriesByShop[category.shop] = categoriesByShop[category.shop] or {}
		local bucket = categoriesByShop[category.shop]
		bucket[#bucket + 1] = category
	end

	for _, offer in ipairs(parsedOffers) do
		offers[offer.id] = offer
		local bucket = offersByCategory[offer.category]
		if bucket then
			bucket[#bucket + 1] = offer
		end
	end

	balances = parsedBalances

	if not tokenShopWindow then
		return
	end

	if selectedShop and shops[selectedShop] then
		selectShop(selectedShop)
	elseif shopOrder[1] then
		selectShop(shopOrder[1])
	end
end

local function onBalance(msg)
	local count = msg:getU8()
	for _ = 1, count do
		local shopId = msg:getU8()
		balances[shopId] = msg:getU32()
	end
	refreshBalance()
	refreshTotal()
end

local function onResult(msg)
	local code = msg:getU8()
	local offerId = msg:getU16()
	local count = msg:getU16()
	local message = msg:getString()

	if code == 0 then
		local offer = offers[offerId]
		if offer then
			modules.game_textmessage.displayGameMessage(
				tr('Bought %dx %s.', count, offer.name))
		end
		return
	end

	if message == '' then
		message = RESULT_MESSAGES[code] or tr('Purchase failed.')
	end

	modules.game_textmessage.displayFailureMessage(message)
end

local function onShopPacket(protocol, msg)
	local subtype = msg:getU8()

	if subtype == S2C_CATALOG then
		onCatalog(msg)
	elseif subtype == S2C_BALANCE then
		onBalance(msg)
	elseif subtype == S2C_RESULT then
		onResult(msg)
	end
end

-- ============================================================
-- UI
-- ============================================================

function onBuyClicked()
	if not selectedOffer then
		return
	end

	local countBox = tokenShopWindow:recursiveGetChildById('countBox')
	send(C2S_BUY, selectedOffer.id, countBox:getValue())
end

function onCountChanged()
	refreshTotal()
end

function show()
	if not tokenShopWindow then
		return
	end
	tokenShopWindow:show()
	tokenShopWindow:raise()
	tokenShopWindow:focus()
	requestCatalog()
end

function hide()
	if not tokenShopWindow then
		return
	end
	tokenShopWindow:hide()
end

function toggle()
	if not tokenShopWindow then
		return
	end
	if tokenShopWindow:isVisible() then
		hide()
	else
		show()
	end
end

local function onGameStart()
	ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	ProtocolGame.registerOpcode(OPCODE_SERVER, onShopPacket)
end

local function onGameEnd()
	shops = {}
	shopOrder = {}
	categories = {}
	offers = {}
	offersByCategory = {}
	categoriesByShop = {}
	categoryRows = {}
	offerSlots = {}
	selectedShop = nil
	selectedCategory = nil
	selectedOffer = nil
	balances = {}
	hide()
end

function init()
	tokenShopWindow = g_ui.displayUI('tokenshop')
	tokenShopWindow:hide()

	-- Sinais antes da UI opcional: o protocolo nao pode depender dela.
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	onGameStart()

	local countBox = tokenShopWindow:recursiveGetChildById('countBox')
	if countBox then
		countBox.onValueChange = onCountChanged
	end

	pcall(function()
		UIModalOverlay.register(tokenShopWindow)
	end)

	renderDetail()

	if g_game.isOnline() then
		requestCatalog()
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	ProtocolGame.unregisterOpcode(OPCODE_SERVER)

	if tokenShopWindow then
		tokenShopWindow:destroy()
		tokenShopWindow = nil
	end

	categories = {}
	offers = {}
	offersByCategory = {}
	categoryRows = {}
	offerSlots = {}
end

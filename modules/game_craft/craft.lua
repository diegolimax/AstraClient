-- Craft System :: AstraClient module
-- modules/game_craft/craft.lua
--
-- Le o opcode nativo 0x59 e responde no 0x58. Nenhuma receita vive neste
-- arquivo: o servidor manda o catalogo (com nomes, descricoes, materiais e
-- quantas unidades o jogador tem de cada material) e o saldo do banco.
-- Portado do ZerionOT (game_crafting, extended opcode 242 + JSON + talkaction)
-- e reescrito em wire format binario, no padrao do game_dungeon.

craftWindow = nil

local OPCODE_SERVER = 0x59
local OPCODE_CLIENT = 0x58

local S2C_CATALOG = 0x00
local S2C_RESULT = 0x01

local C2S_REQUEST_CATALOG = 0x00
local C2S_CRAFT = 0x01

local RESULT_OK = 0

-- Tem que bater com Config.categories do servidor (ordem e ids).
local CATEGORIES = {
	{ id = 1, key = 'weapons' },
	{ id = 2, key = 'equipments' },
	{ id = 3, key = 'alchemist' },
	{ id = 4, key = 'enchanter' },
	{ id = 5, key = 'jeweller' },
}

local categoryIdByKey = {}
local categoryKeyById = {}
for _, category in ipairs(CATEGORIES) do
	categoryIdByKey[category.key] = category.id
	categoryKeyById[category.id] = category.key
end

local categoriesPanel = nil
local craftPanel = nil
local itemsList = nil

local Crafts = {}
local money = 0
local selectedCategory = nil
local selectedCraftId = nil
local craftCount = 1
local isCrafting = false
local isCraftingUpdate = false

local function formatNumber(value)
	value = tostring(math.floor(tonumber(value) or 0))
	local formatted = value
	while true do
		local replaced
		formatted, replaced = formatted:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
		if replaced == 0 then
			break
		end
	end
	return formatted
end

-- ============================================================
-- ENVIO
-- ============================================================

local function send(action, categoryId, recipeIndex, count)
	local protocolGame = g_game.getProtocolGame()
	if not protocolGame then
		return false
	end

	local msg = OutputMessage.create()
	msg:addU8(OPCODE_CLIENT)
	msg:addU8(action)
	msg:addU8(categoryId)
	if recipeIndex then
		msg:addU16(recipeIndex)
		msg:addU16(count or 1)
	end
	protocolGame:send(msg)
	return true
end

local function requestCatalog(categoryKey)
	local categoryId = categoryIdByKey[categoryKey]
	if categoryId then
		send(C2S_REQUEST_CATALOG, categoryId)
	end
end

-- ============================================================
-- LEITURA
-- ============================================================

local function parseCatalog(msg)
	local categoryId = msg:getU8()
	local balance = msg:getU64()
	local recipes = {}

	local count = msg:getU16()
	for i = 1, count do
		local recipe = {}
		recipe.clientId = msg:getU16()
		recipe.name = msg:getString()
		recipe.level = msg:getU16()
		recipe.cost = msg:getU32()
		recipe.count = msg:getU8()
		recipe.stackable = msg:getU8() == 1
		recipe.desc = msg:getString()

		recipe.materials = {}
		local materialCount = msg:getU8()
		for j = 1, materialCount do
			recipe.materials[j] = {
				id = msg:getU16(),
				count = msg:getU16(),
				name = msg:getString(),
				player = msg:getU32(),
			}
		end

		recipes[i] = recipe
	end

	return categoryKeyById[categoryId], balance, recipes
end

-- ============================================================
-- UI
-- ============================================================

local function updateMoney()
	if craftPanel then
		local label = craftPanel:recursiveGetChildById('playerMoney')
		if label then
			label:setText(formatNumber(money))
		end
	end
end

function refreshItem(id)
	local craftId = tonumber(id)
	if not craftId or not selectedCategory or not Crafts[selectedCategory]
		or craftId < 1 or craftId > #Crafts[selectedCategory] then
		return
	end

	selectedCraftId = craftId
	local craft = Crafts[selectedCategory][craftId]

	local countInput = craftPanel:getChildById('craftCountInput')
	if countInput then
		countInput:setEnabled(craft.stackable)
		countInput:setEditable(craft.stackable)
		if not craft.stackable then
			craftCount = 1
			countInput:setText('1')
		end
	end

	for i = 1, 6 do
		local materialWidget = craftPanel:getChildById('material' .. i)
		if materialWidget then
			materialWidget:setItemId(0)
			materialWidget:setTooltip('')
		end
		local countWidget = craftPanel:getChildById('count' .. i)
		if countWidget then
			countWidget:setText('')
		end
	end

	for i = 1, math.min(#craft.materials, 6) do
		local material = craft.materials[i]
		local materialWidget = craftPanel:getChildById('material' .. i)
		local countWidget = craftPanel:getChildById('count' .. i)
		if materialWidget and countWidget then
			materialWidget:setItemId(material.id)
			materialWidget:setTooltip(material.name)
			local requiredCount = material.count * craftCount
			countWidget:setText(material.player .. '\n' .. requiredCount)
			countWidget:setColor(material.player >= requiredCount and '#FFFFFF' or '#FF0000')
		end
	end

	local outcome = craftPanel:getChildById('craftOutcome')
	if outcome then
		outcome:setItemId(craft.clientId)
		outcome:setItemCount(craft.count * craftCount)
		outcome:setTooltip(craft.desc or '')
	end

	local totalCost = craftPanel:recursiveGetChildById('totalCost')
	if totalCost then
		totalCost:setText(formatNumber(craft.cost * craftCount))
	end

	local itemWidget = itemsList:getChildById(tostring(craftId))
	if itemWidget then
		itemWidget:focus()
	end
end

function selectCategory(categoryKey)
	if not categoryIdByKey[categoryKey] then
		return
	end

	if selectedCategory then
		local oldButton = categoriesPanel:getChildById(selectedCategory .. 'Cat')
		if oldButton then
			oldButton:setOn(false)
		end
	end

	local newButton = categoriesPanel:getChildById(categoryKey .. 'Cat')
	if newButton then
		newButton:setOn(true)
	end
	selectedCategory = categoryKey

	if not Crafts[categoryKey] or #Crafts[categoryKey] == 0 then
		-- catalogo ainda nao chegou: pede e popula quando o pacote voltar
		requestCatalog(categoryKey)
		return
	end

	populateList()
end

function populateList()
	if not selectedCategory or not Crafts[selectedCategory] then
		return
	end

	itemsList:destroyChildren()
	selectedCraftId = nil

	for i = 1, #Crafts[selectedCategory] do
		local craft = Crafts[selectedCategory][i]
		local row = g_ui.createWidget('CraftListItem')
		row:setId(i)
		row:getChildById('item'):setItemId(craft.clientId)
		row:getChildById('name'):setText(craft.name)
		row:getChildById('level'):setText('Required Level ' .. craft.level)
		row:setTooltip(craft.desc or '')
		itemsList:addChild(row)

		row.onClick = function(widget)
			refreshItem(widget:getId())
		end

		if i == 1 then
			row:focus()
			refreshItem(1)
		end
	end
end

function onSearch()
	scheduleEvent(function()
		if not craftWindow then
			return
		end
		local searchInput = craftWindow:recursiveGetChildById('searchInput')
		if not searchInput then
			return
		end
		local text = searchInput:getText():lower()
		local children = itemsList:getChildCount()
		for i = children, 1, -1 do
			local child = itemsList:getChildByIndex(i)
			if text:len() >= 1 then
				local name = child:getChildById('name'):getText():lower()
				if name:find(text, 1, true) then
					child:show()
					child:focus()
					refreshItem(child:getId())
				else
					child:hide()
				end
			else
				child:show()
				child:focus()
				refreshItem(child:getId())
			end
		end
	end, 25)
end

function updateCraftCost()
	if not craftWindow or not craftPanel then
		return
	end

	local countInput = craftWindow:recursiveGetChildById('craftCountInput')
	if not countInput then
		return
	end

	if not selectedCategory or not selectedCraftId then
		return
	end
	local craft = Crafts[selectedCategory] and Crafts[selectedCategory][selectedCraftId]
	if not craft then
		return
	end

	local inputText = countInput:getText()
	local newCount = tonumber(inputText)

	if not inputText or inputText == '' or not newCount or newCount < 1 then
		craftCount = 1
		countInput:setText('1')
	else
		if newCount > 1000 then
			newCount = 1000
			countInput:setText('1000')
		end
		craftCount = newCount
	end

	refreshItem(selectedCraftId)
end

local function playCraftAnimation()
	if not selectedCategory or not selectedCraftId then
		return
	end
	local craft = Crafts[selectedCategory][selectedCraftId]
	if not craft then
		return
	end

	for i = 1, math.min(#craft.materials, 6) do
		local lineWidget = craftPanel:getChildById('craftLine' .. i)
		if lineWidget then
			lineWidget:setImageSource('/images/crafting/craft_line' .. i .. 'on')
			scheduleEvent(function()
				if lineWidget then
					lineWidget:setImageSource('/images/crafting/craft_line' .. (i == 2 and 5 or i))
				end
			end, 850)
		end
	end

	local button = craftPanel:recursiveGetChildById('craftButton')
	if button then
		button:disable()
		scheduleEvent(function()
			if button then
				button:enable()
			end
			isCrafting = false
			if selectedCraftId then
				refreshItem(selectedCraftId)
			end
			local countInput = craftPanel:getChildById('craftCountInput')
			if countInput then
				countInput:setText('1')
			end
			craftCount = 1
		end, 850)
	end
end

function craftItem()
	if not selectedCategory or not selectedCraftId or isCrafting then
		return
	end

	local categoryId = categoryIdByKey[selectedCategory]
	if not categoryId then
		return
	end

	isCrafting = true
	local button = craftPanel:recursiveGetChildById('craftButton')
	if button then
		button:setEnabled(false)
		scheduleEvent(function()
			if button then
				button:setEnabled(true)
			end
			isCrafting = false
		end, 850)
	end

	send(C2S_CRAFT, categoryId, selectedCraftId, craftCount)
end

-- ============================================================
-- PACOTES
-- ============================================================

local function onCraftPacket(protocol, msg)
	local subtype = msg:getU8()

	if subtype == S2C_CATALOG then
		local categoryKey, balance, recipes = parseCatalog(msg)
		if not categoryKey then
			return
		end

		Crafts[categoryKey] = recipes
		money = balance
		updateMoney()

		if isCraftingUpdate then
			-- refresh pos-craft: mantem o item selecionado, so atualiza contagens
			isCraftingUpdate = false
			if selectedCategory == categoryKey and selectedCraftId then
				refreshItem(selectedCraftId)
			end
		elseif selectedCategory == categoryKey then
			populateList()
		end
	elseif subtype == S2C_RESULT then
		local code = msg:getU8()
		local message = msg:getString()
		if code == RESULT_OK then
			isCraftingUpdate = true
			playCraftAnimation()
		end
		-- Mensagens de erro chegam tambem pelo console do jogo (servidor).
	end
end

-- ============================================================
-- JANELA
-- ============================================================

function show()
	if not craftWindow then
		return
	end
	craftWindow:show()
	craftWindow:raise()
	craftWindow:focus()
	selectCategory(selectedCategory or 'weapons')
	-- forca refresh do saldo/materiais mesmo com catalogo em cache
	requestCatalog(selectedCategory or 'weapons')
end

function hide()
	if not craftWindow then
		return
	end
	craftWindow:hide()
end

function toggle()
	if not craftWindow then
		return
	end
	if craftWindow:isVisible() then
		hide()
	else
		show()
	end
end

local function onGameStart()
	-- registerOpcode lanca error() se o opcode ja estiver ocupado. Limpar antes
	-- evita que um handler orfao (reload do modulo) impeca o registro real.
	ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	ProtocolGame.registerOpcode(OPCODE_SERVER, onCraftPacket)
end

local function onGameEnd()
	-- NAO desregistrar o opcode aqui (mesma logica do game_dungeon).
	Crafts = {}
	money = 0
	selectedCategory = nil
	selectedCraftId = nil
	craftCount = 1
	isCrafting = false
	isCraftingUpdate = false
	hide()
end

function init()
	craftWindow = g_ui.displayUI('craft')
	craftWindow:hide()

	categoriesPanel = craftWindow:getChildById('categories')
	craftPanel = craftWindow:getChildById('craftPanel')
	itemsList = craftWindow:getChildById('itemsList')

	local countInput = craftWindow:recursiveGetChildById('craftCountInput')
	if countInput then
		countInput:setText('1')
		craftCount = 1
	end

	-- Sinais PRIMEIRO: o protocolo nunca pode depender de a UI opcional existir.
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	-- registerOpcode apenas grava numa tabela Lua do gamelib: nao exige conexao
	-- ativa. Registrar aqui, incondicionalmente, igual ao game_dungeon.
	onGameStart()

	local ok, err = pcall(function()
		UIModalOverlay.register(craftWindow)
	end)
	if not ok then
		g_logger.warning('[game_craft] UIModalOverlay indisponivel: ' .. tostring(err))
	end

	-- O botao lateral e registrado em modules/game_sidebuttons/sidebuttons.lua
	-- sob o id "craftDialog", que despacha para modules.game_craft.toggle().
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	if g_game.isOnline() then
		ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	end

	if craftWindow then
		craftWindow:destroy()
		craftWindow = nil
	end

	categoriesPanel = nil
	craftPanel = nil
	itemsList = nil
	Crafts = {}
	selectedCategory = nil
	selectedCraftId = nil
end

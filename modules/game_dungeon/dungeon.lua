-- Dungeon System :: AstraClient module
-- modules/game_dungeon/dungeon.lua
--
-- Le o opcode nativo 0x55 e responde no 0x54. Nenhum dado de dungeon
-- vive neste arquivo: o servidor manda catalogo, loot e estado.

dungeonWindow = nil
dungeonButton = nil

local OPCODE_SERVER = 0x55
local OPCODE_CLIENT = 0x54

local S2C_CATALOG = 0x00
local S2C_STATE = 0x01
local S2C_RESULT = 0x02

local C2S_REQUEST_CATALOG = 0x00
local C2S_ENTER = 0x01
local C2S_ENTER_PARTY = 0x03

local RARITY = {
	[0] = { label = 'common', color = '#bcd3f7' },
	[1] = { label = 'rare', color = '#0af20a' },
	[2] = { label = 'very rare', color = '#dff20a' },
	[3] = { label = 'super rare', color = '#ea0af2' },
	[4] = { label = 'ultra rare', color = '#d40d06' },
}

local RESULT_MESSAGES = {
	[1] = 'Your level is too low for this dungeon.',
	[2] = 'This dungeon is still on cooldown.',
	[3] = 'You must be in the temple to enter.',
	[4] = 'All dungeon rooms are busy right now.',
	[5] = 'Only the party leader can start a dungeon.',
	[6] = 'Your party has too many members.',
	[7] = 'Players sharing an IP cannot enter together.',
	[8] = 'Dungeons are closed: server save is near.',
	[9] = 'You have no boss charges for this dungeon.',
	[10] = 'This dungeon is not available.',
	[11] = 'You need a party to enter in group mode.',
	[12] = 'A party member does not meet the requirements.',
}

local dungeons = {}
local dungeonRows = {}
local selectedId = nil
local state = { activeId = 0, remaining = 0, kills = 0, required = 0 }
local partyInfo = { maxSize = 4, healthPerMember = 10, lootPerMember = 10 }
local cooldownInfo = { base = 0, free = 0, vip = 0 }
local countdownEvent = nil

-- ============================================================
-- ENVIO
-- ============================================================

local function send(action, dungeonId)
	local protocolGame = g_game.getProtocolGame()
	if not protocolGame then
		return false
	end

	local msg = OutputMessage.create()
	msg:addU8(OPCODE_CLIENT)
	msg:addU8(action)
	if dungeonId then
		msg:addU8(dungeonId)
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

local function readOutfit(msg)
	local outfit = { type = msg:getU16() }
	outfit.head = msg:getU8()
	outfit.body = msg:getU8()
	outfit.legs = msg:getU8()
	outfit.feet = msg:getU8()
	outfit.addons = msg:getU8()
	return outfit
end

-- S2C_STATE envia SO estes 4 campos (atualizacao leve). Os 3 bytes de party
-- existem apenas no S2C_CATALOG -- ler aqui estourava o buffer no onState e
-- dessincronizava o stream inteiro (eof reached / unhandled opcode 85).
local function readState(msg)
	return {
		activeId = msg:getU8(),
		remaining = msg:getU32(),
		kills = msg:getU32(),
		required = msg:getU32(),
	}
end

-- Bytes extras que so o catalogo carrega, logo apos o bloco de estado.
local function readPartyInfo(msg)
	partyInfo.maxSize = msg:getU8()
	partyInfo.healthPerMember = msg:getU8()
	partyInfo.lootPerMember = msg:getU8()
end

-- Cooldown base + bonus de reducao (itens Free/VIP), so no catalogo.
local function readCooldownInfo(msg)
	cooldownInfo.base = msg:getU32()
	cooldownInfo.free = msg:getU32()
	cooldownInfo.vip = msg:getU32()
end

local function parseCatalog(msg)
	local list = {}
	local count = msg:getU8()

	for _ = 1, count do
		local entry = {}
		entry.id = msg:getU8()
		entry.name = msg:getString()
		entry.level = msg:getU16()
		entry.outfit = readOutfit(msg)
		entry.bossName = msg:getString()
		entry.minutes = msg:getU16()
		entry.requiredKills = msg:getU16()
		entry.cooldown = msg:getU32()
		entry.charges = msg:getU16()

		entry.bossLoot = {}
		local bossLootCount = msg:getU8()
		for _ = 1, bossLootCount do
			entry.bossLoot[#entry.bossLoot + 1] = {
				clientId = msg:getU16(),
				rarity = msg:getU8(),
				name = msg:getString(),
			}
		end

		entry.randomLoot = {}
		local randomLootCount = msg:getU8()
		for _ = 1, randomLootCount do
			entry.randomLoot[#entry.randomLoot + 1] = {
				clientId = msg:getU16(),
				count = msg:getU16(),
				label = msg:getString(),
				image = msg:getString(),
			}
		end

		list[#list + 1] = entry
	end

	local newState = readState(msg)
	readPartyInfo(msg)
	readCooldownInfo(msg)

	return list, newState
end

-- ============================================================
-- RENDER
-- ============================================================

local function formatTime(seconds)
	seconds = math.max(0, seconds)
	return string.format('%02d:%02d', math.floor(seconds / 60), seconds % 60)
end

-- Cooldown pode chegar a 20h, entao formato longo separado do cronometro.
local function formatCooldown(seconds)
	seconds = math.max(0, seconds)
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		return string.format('%dh %dmin', hours, minutes)
	end
	return string.format('%dmin', math.max(1, minutes))
end

local function setRow(id, label, value, color)
	local row = dungeonWindow:recursiveGetChildById(id)
	if not row then
		return
	end
	row:getChildById('rowLabel'):setText(tr(label))
	local valueLabel = row:getChildById('rowValue')
	valueLabel:setText(value)
	valueLabel:setColor(color or '$var-text-cip-color-white')
end

local function buildLootSlot(parent, clientId, caption, captionColor, image, tooltip)
	local slot = g_ui.createWidget('DungeonLootSlot', parent)
	local item = slot:getChildById('item')

	-- Imagem custom e opcional. O OTClient carrega textura de forma preguicosa:
	-- setImageSource so guarda o caminho e o arquivo so e aberto na hora de
	-- desenhar, ja fora daqui. Por isso pcall nao resolve e a checagem tem que
	-- acontecer ANTES de setar.
	if image and image ~= '' then
		local path = image
		if not path:match('%.%a+$') then
			path = path .. '.png'
		end
		if g_resources.fileExists(path) then
			item:setImageSource(path)
		end
	end
	if clientId and clientId > 0 then
		item:setItemId(clientId)
	end

	local captionLabel = slot:getChildById('caption')
	captionLabel:setText(caption)
	captionLabel:setColor(captionColor or '$var-text-cip-color')

	-- tooltip mostra o nome real do item; a legenda visivel pode ser outra coisa
	-- (a raridade, no caso do boss loot)
	local hint = tooltip
	if not hint or hint == '' then
		hint = caption
	end
	slot:setTooltip(hint)
	return slot
end

local function updateEnterButtons(entry)
	local soloButton = dungeonWindow:recursiveGetChildById('enterSoloButton')
	local partyButton = dungeonWindow:recursiveGetChildById('enterPartyButton')

	local available = entry ~= nil and entry.cooldown == 0 and state.activeId == 0
	soloButton:setEnabled(available)
	partyButton:setEnabled(available)

	if entry then
		partyButton:setTooltip(tr(
			'Takes your whole party (max %d). Each extra member: +%d%% monster health and damage, +%d%% loot.',
			partyInfo.maxSize,
			partyInfo.healthPerMember,
			partyInfo.lootPerMember
		))
		soloButton:setTooltip(tr('Enter alone, ignoring your party.'))
	end
end

local function renderDetails()
	local entry = dungeons[selectedId]
	local bossLootPanel = dungeonWindow:recursiveGetChildById('bossLootPanel')
	local randomLootPanel = dungeonWindow:recursiveGetChildById('randomLootPanel')

	bossLootPanel:destroyChildren()
	randomLootPanel:destroyChildren()

	local enterButton = dungeonWindow:recursiveGetChildById('enterButton')

	if not entry then
		dungeonWindow:recursiveGetChildById('bossOutfit'):hide()
		dungeonWindow:recursiveGetChildById('bossName'):setText('')
		setRow('rowLevel', 'Required level', '-')
		setRow('rowTime', 'Duration', '-')
		setRow('rowKills', 'Creatures', '-')
		setRow('rowStatus', 'Status', '-')
		setRow('rowCharges', 'Boss charges', '-')
		setRow('rowCooldown', 'Cooldown', '-')
		updateEnterButtons(nil)
		return
	end

	local bossOutfit = dungeonWindow:recursiveGetChildById('bossOutfit')
	bossOutfit:show()
	bossOutfit:setOutfit(entry.outfit)
	bossOutfit:setAnimate(true)
	bossOutfit:setCenter(true)

	dungeonWindow:recursiveGetChildById('bossName'):setText(entry.bossName)

	setRow('rowLevel', 'Required level', comma_value(entry.level))
	setRow('rowTime', 'Duration', string.format('%d min', entry.minutes))
	setRow('rowKills', 'Creatures', comma_value(entry.requiredKills))
	setRow(
		'rowStatus',
		'Status',
		entry.cooldown > 0 and formatCooldown(entry.cooldown) or tr('Available'),
		entry.cooldown > 0 and '#d40d06' or '#0af20a'
	)
	setRow('rowCharges', 'Boss charges', tostring(entry.charges))

	-- Cooldown base + bonus dos itens de reducao (Free/VIP)
	local totalReduction = cooldownInfo.free + cooldownInfo.vip
	local effective = math.max(0, cooldownInfo.base - totalReduction)
	local cooldownRow = dungeonWindow:recursiveGetChildById('rowCooldown')
	if totalReduction > 0 then
		setRow(
			'rowCooldown',
			'Cooldown',
			string.format('%s (-%s)',
				effective > 0 and formatCooldown(effective) or tr('None'),
				formatCooldown(totalReduction)),
			'#0af20a'
		)
		if cooldownRow then
			cooldownRow:setTooltip(tr(
				'Base cooldown: %s\nVIP Cooldown bonus: -%s\nFree Cooldown bonus: -%s\nTotal reduction: -%s\nEffective cooldown: %s',
				formatCooldown(cooldownInfo.base),
				cooldownInfo.vip > 0 and formatCooldown(cooldownInfo.vip) or '0min',
				cooldownInfo.free > 0 and formatCooldown(cooldownInfo.free) or '0min',
				formatCooldown(totalReduction),
				effective > 0 and formatCooldown(effective) or tr('None')
			))
		end
	else
		setRow('rowCooldown', 'Cooldown', formatCooldown(cooldownInfo.base))
		if cooldownRow then
			cooldownRow:setTooltip(tr('Use VIP/Free Cooldown Reduction items to lower this.'))
		end
	end

	for _, loot in ipairs(entry.bossLoot) do
		local rarity = RARITY[loot.rarity] or RARITY[0]
		buildLootSlot(bossLootPanel, loot.clientId, tr(rarity.label), rarity.color, nil, loot.name)
	end

	for _, loot in ipairs(entry.randomLoot) do
		local caption = loot.count > 1 and string.format('%dx %s', loot.count, loot.label) or loot.label
		buildLootSlot(randomLootPanel, loot.clientId, caption, '$var-text-cip-color', loot.image, loot.label)
	end

	updateEnterButtons(entry)
end

local function refreshStatusLabel()
	local label = dungeonWindow:recursiveGetChildById('statusLabel')
	if not label then
		return
	end

	if state.activeId == 0 then
		label:setText('')
		return
	end

	local active = dungeons[state.activeId]
	label:setText(tr(
		'In dungeon %s  -  %s left  -  %d/%d kills',
		active and active.name or '?',
		formatTime(state.remaining),
		state.kills,
		state.required
	))
end

local function stopCountdown()
	if countdownEvent then
		removeEvent(countdownEvent)
		countdownEvent = nil
	end
end

local function tickCountdown()
	countdownEvent = nil
	if state.activeId == 0 then
		return
	end

	state.remaining = math.max(0, state.remaining - 1)
	refreshStatusLabel()

	if state.remaining > 0 then
		countdownEvent = scheduleEvent(tickCountdown, 1000)
	end
end

local function startCountdown()
	stopCountdown()
	if state.activeId ~= 0 and state.remaining > 0 then
		countdownEvent = scheduleEvent(tickCountdown, 1000)
	end
end

local function rebuildList()
	local list = dungeonWindow:recursiveGetChildById('dungeonList')
	list:destroyChildren()
	dungeonRows = {}

	for _, entry in ipairs(dungeons.ordered) do
		local row = g_ui.createWidget('DungeonListButton', list)
		row.dungeonId = entry.id

		local outfit = row:getChildById('outfit')
		outfit:setOutfit(entry.outfit)
		outfit:setAnimate(true)
		outfit:setCenter(true)

		row:getChildById('title'):setText(entry.name)
		row:getChildById('subtitle'):setText(tr('Level %s', comma_value(entry.level)))
		row:getChildById('doneMark'):setVisible(entry.cooldown > 0)

		row.onClick = function(widget)
			selectDungeon(widget.dungeonId)
		end

		dungeonRows[entry.id] = row
	end
end

function selectDungeon(dungeonId)
	selectedId = dungeonId

	for id, row in pairs(dungeonRows) do
		row:setChecked(id == dungeonId)
	end

	renderDetails()
end

-- ============================================================
-- HANDLERS DE PACOTE
-- ============================================================

local function onCatalog(msg)
	local list, newState = parseCatalog(msg)

	dungeons = {}
	dungeons.ordered = list
	for _, entry in ipairs(list) do
		dungeons[entry.id] = entry
	end

	state = newState

	if not dungeonWindow then
		return
	end

	rebuildList()

	if selectedId and dungeons[selectedId] then
		selectDungeon(selectedId)
	elseif list[1] then
		selectDungeon(list[1].id)
	else
		renderDetails()
	end

	refreshStatusLabel()
	startCountdown()
end

local function onState(msg)
	state = readState(msg)

	if not dungeonWindow then
		return
	end

	refreshStatusLabel()
	startCountdown()
	updateEnterButtons(selectedId and dungeons[selectedId])
end

local function onResult(msg)
	local code = msg:getU8()
	local message = msg:getString()

	if code == 0 then
		return
	end

	if message == '' then
		message = RESULT_MESSAGES[code] or tr('Action failed.')
	end

	modules.game_textmessage.displayFailureMessage(message)
end

local function onDungeonPacket(protocol, msg)
	local subtype = msg:getU8()

	if subtype == S2C_CATALOG then
		onCatalog(msg)
	elseif subtype == S2C_STATE then
		onState(msg)
	elseif subtype == S2C_RESULT then
		onResult(msg)
	end
end

-- ============================================================
-- UI
-- ============================================================

function onEnterClicked()
	if not selectedId then
		return
	end
	send(C2S_ENTER, selectedId)
end

function onEnterPartyClicked()
	if not selectedId then
		return
	end
	send(C2S_ENTER_PARTY, selectedId)
end

function show()
	if not dungeonWindow then
		return
	end
	dungeonWindow:show()
	dungeonWindow:raise()
	dungeonWindow:focus()
	if dungeonButton then
		dungeonButton:setOn(true)
	end
	requestCatalog()
end

function hide()
	if not dungeonWindow then
		return
	end
	dungeonWindow:hide()
	if dungeonButton then
		dungeonButton:setOn(false)
	end
end

function toggle()
	if not dungeonWindow then
		return
	end
	if dungeonWindow:isVisible() then
		hide()
	else
		show()
	end
end

local function onGameStart()
	-- registerOpcode lanca error() se o opcode ja estiver ocupado. Limpar antes
	-- evita que um handler orfao (reload do modulo, teste manual no terminal)
	-- impeca o registro real.
	ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	ProtocolGame.registerOpcode(OPCODE_SERVER, onDungeonPacket)
end

local function onGameEnd()
	-- NAO desregistrar aqui: o handler e apenas uma entrada de tabela no gamelib e
	-- mante-lo entre sessoes e inofensivo. Remover no logout faria o registro
	-- depender de o sinal onGameStart disparar no proximo login.
	stopCountdown()
	dungeons = {}
	dungeonRows = {}
	selectedId = nil
	state = { activeId = 0, remaining = 0, kills = 0, required = 0 }
	cooldownInfo = { base = 0, free = 0, vip = 0 }
	hide()
end

function init()
	dungeonWindow = g_ui.displayUI('dungeon')
	dungeonWindow:hide()

	-- Sinais PRIMEIRO: o protocolo nunca pode depender de a UI opcional existir.
	-- Se algo abaixo falhar, o opcode 0x55 ja esta registrado.
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	-- registerOpcode apenas grava numa tabela Lua do gamelib: nao exige conexao
	-- ativa nem precisa esperar o login. Registrar aqui, incondicionalmente,
	-- elimina a dependencia do sinal onGameStart, que e onde isso vinha falhando.
	onGameStart()

	if g_game.isOnline() then
		requestCatalog()
	end

	-- Daqui pra baixo e tudo opcional e isolado: APIs que podem nao existir
	-- nesta build nao podem matar o modulo inteiro.
	local ok, err = pcall(function()
		UIModalOverlay.register(dungeonWindow)
	end)
	if not ok then
		g_logger.warning('[game_dungeon] UIModalOverlay indisponivel: ' .. tostring(err))
	end

	-- NOTA: game_mainpanel.addToggleButton NAO funciona nesta build. O painel
	-- rightGameButtonsPanel nasce com visible:false no estilo e so e revelado pelo
	-- showGameButtons() no login, e o game_buttons esta inativo (forceOpen falso).
	-- O botao real e registrado em modules/game_sidebuttons/sidebuttons.lua sob o
	-- id "dungeonDialog", que despacha para modules.game_dungeon.toggle().
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	if g_game.isOnline() then
		ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	end

	stopCountdown()

	if dungeonButton then
		dungeonButton:destroy()
		dungeonButton = nil
	end

	if dungeonWindow then
		dungeonWindow:destroy()
		dungeonWindow = nil
	end

	dungeons = {}
	dungeonRows = {}
	selectedId = nil
end
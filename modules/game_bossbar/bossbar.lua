-- Boss Bar :: AstraClient module
-- modules/game_bossbar/bossbar.lua
--
-- 100% client-side: no protocolo 8.60 a vida das criaturas ja chega como
-- porcentagem nas atualizacoes normais. Nao existe opcode nem servidor aqui.

local config = {
	-- Criterio 1: caveira preta (convencao do ZerionOT). Depende do SERVIDOR
	-- marcar o monstro, o que pode nao ter sido migrado para o TFS 1.8.
	bossSkull = SkullBlack,

	-- Criterio 2: nome na lista. Nao depende de nada no servidor.
	-- Comparacao e case-insensitive. Sao os bosses do Dungeon System.
	bossNames = {
		'drume',
		'ferumbras',
		'orshabaal',
		'ghazbaran',
		'morgaroth',
		'zulazza the corruptor',
		'madareth',
		'the pale count',
		'the horned fox',
		'the mutated pumpkin',
		'the welter',
		'the void',
		'the fear feaster',
		'the dread maiden',
		'the ancient one',
		'the time guardian',
		'the enraged thorn knight',
		'the last lore keeper',
		'the scourge of oblivion',
		'urmahlullu the weakened',
		'urmahlullu',
		'world devourer',
		'brain head',
		'unzag',
		'vok the freakish',
		'the monster',
		'goshnar\'s malice',
		'goshnar\'s hatred',
		'goshnar\'s greed',
		'goshnar\'s spite',
		'goshnar\'s cruelty',
		'goshnar\'s megalomania',
		'goshnar\'s avatar',
		'goshnar\'s greed',
		'lady tenebris',
		'lloyd',
		'melting frozen horror',
		'dragonking zyrtarch',
		'ancient spawn of morgathla',
		'morgathla',
		'king zelos',
		'scarlett etzel',
		'the oberon',
		'grand master oberon',
		'the duke of the depths',
		'urmahlullu',
		'the first dragon',
		'the enraged thorn knight',
		'the sandking',
		'the count of the core',
		'the false god',
		'the flaming orchid',
		'the moonlight aster',
		'the winter bloom',
		'the thorn knight',
		'the sinister hermit',
		'the blazing rose',
		'the nightmare beast',
		'the faceless bane',
		'the souldespoiler',
		'the dread maiden',
		'the fear feaster',
		'the unwelcome',
		'the coddler',
		'the primal menace',
		'the shattered soul',
		'timira the many-headed',
		'alptramun',
		'izcandar the banished',
		'izcandar champion of summer',
		'izcandar champion of winter',
		'the lion',
		'the scourge of oblivion',
		'essence of malice',
		'tentugly',
		'the snapper',
		'leiden',
		'brokul',
		'custodian',
		'guardian of tales',
		'the source of corruption',
		'the souldespoiler',
		'the cloak of terror',
		'the rootkraken',
		'bakragore',
		'cruelty',
		'hatred',
		'malice',
		'spite',
		'greed',
		'megalomania',
		'the false god',
		'the bloodtusk',
		'the dark dancer',
		'the armoured voidborn',
		'the twisted gnarl',
		'the enraged emerald',
		'the blazing emerald',
		'the tainted soul',
		'the distorted phantom',
		'the ravager',
		'the keeper',
		'the guardian',
		'the destroyer',
		'the purifier',
		'the enraged giant',
		'the baron from below',
		'the count of the core',
		'the duke of the depths',
		'the lord of the lice',
		'the marquis of magnificence',
		'the nightmare beast',
		'the source of corruption',
		
		'aetherius',
		'chronor',
		'erebos',
		'malachor',
	},

	-- Nomes que batem em algum destes padroes nunca viram boss.
	ignorePatterns = { '%[Fishing%]' },

	-- Mostra a barra SOMENTE quando voce esta atacando o boss. Com varios
	-- bosses juntos na mesma sala, chegar perto nao dispara mais nada.
	onlyWhenAttacking = true,

	-- Mostra tambem a criatura que voce esta atacando, mesmo sem ser boss.
	-- Era isto que fazia a barra aparecer em qualquer monstro.
	trackAttacked = false,

	-- Some sozinho depois deste tempo sem nenhuma atualizacao de vida.
	idleHideSeconds = 12,
}

-- Set montado uma vez a partir de config.bossNames, para busca O(1).
local bossNameSet = {}
for _, name in ipairs(config.bossNames) do
	bossNameSet[name:lower()] = true
end

local window = nil
local current = nil
local lastUpdate = 0
local idleEvent = nil

-- ============================================================
-- SELECAO DO ALVO
-- ============================================================

local function isIgnored(creature)
	local name = creature:getName()
	for _, pattern in ipairs(config.ignorePatterns) do
		if name:find(pattern) then
			return true
		end
	end
	return false
end

local function isVisibleTarget(creature)
	if not creature or creature:isDead() then
		return false
	end

	local player = g_game.getLocalPlayer()
	if not player then
		return false
	end

	local position = creature:getPosition()
	local playerPosition = player:getPosition()
	if not position or not playerPosition then
		return false
	end

	if position.z ~= playerPosition.z then
		return false
	end

	return creature:canBeSeen()
end

local function isBoss(creature)
	if not creature or not creature:isMonster() then
		return false
	end
	if isIgnored(creature) then
		return false
	end

	if creature:getSkull() == config.bossSkull then
		return true
	end

	return bossNameSet[creature:getName():lower()] == true
end

-- Com onlyWhenAttacking: a barra so aparece para o boss que voce esta
-- atacando. Sem: boss visivel tem prioridade; senao, a criatura atacada.
local function pickTarget()
	local player = g_game.getLocalPlayer()
	if not player then
		return nil
	end

	local attacked = g_game.getAttackingCreature()

	if config.onlyWhenAttacking then
		if attacked and isBoss(attacked) and isVisibleTarget(attacked) then
			return attacked
		end
		if config.trackAttacked and attacked and attacked:isMonster()
			and not isIgnored(attacked) and isVisibleTarget(attacked) then
			return attacked
		end
		return nil
	end

	local origin = player:getPosition()
	if not origin then
		return nil
	end

	local best = nil

	for _, creature in ipairs(g_map.getSpectators(origin, false)) do
		if isBoss(creature) and isVisibleTarget(creature) then
			-- entre varios bosses, o de menos vida (o que esta sendo focado)
			if not best or creature:getHealthPercent() < best:getHealthPercent() then
				best = creature
			end
		end
	end

	if best then
		return best
	end

	if config.trackAttacked then
		if attacked and attacked:isMonster() and not isIgnored(attacked) and isVisibleTarget(attacked) then
			return attacked
		end
	end

	return nil
end

-- ============================================================
-- RENDER
-- ============================================================

local function hide()
	if window then
		window:hide()
	end
	current = nil
end

local function refresh()
	if not window then
		return
	end

	if not current or not isVisibleTarget(current) then
		hide()
		return
	end

	local percent = current:getHealthPercent()
	if percent <= 0 then
		hide()
		return
	end

	window:show()
	window:getChildById('bossName'):setText(current:getName())
	window:getChildById('bossPercent'):setText(percent .. '%')

	local bar = window:getChildById('bossHealth')
	bar:setPercent(percent)

	-- verde -> amarelo -> vermelho conforme cai
	local color = '#c62828'
	if percent > 60 then
		color = '#2e7d32'
	elseif percent > 30 then
		color = '#f9a825'
	end
	bar:setBackgroundColor(color)
end

local function evaluate()
	local target = pickTarget()

	if target ~= current then
		current = target
	end

	lastUpdate = os.time()
	refresh()
end

-- ============================================================
-- IDLE
-- ============================================================

local function tickIdle()
	idleEvent = scheduleEvent(tickIdle, 2000)

	if not current then
		return
	end

	if os.time() - lastUpdate >= config.idleHideSeconds then
		-- sem dano ha muito tempo: reavalia em vez de manter barra parada
		evaluate()
	end
end

-- ============================================================
-- SINAIS
-- ============================================================

local function onHealthPercentChange(creature, healthPercent)
	if creature == current then
		lastUpdate = os.time()
		refresh()
		return
	end

	-- criatura nova levando dano pode ser um boss que acabou de entrar em cena
	if isBoss(creature) and isVisibleTarget(creature) then
		evaluate()
	end
end

local function onCreatureAppear(creature)
	if isBoss(creature) then
		evaluate()
	end
end

local function onCreatureDisappear(creature)
	if creature == current then
		evaluate()
	end
end

local function onAttackingCreatureChange(creature, oldCreature)
	-- alvo de ataque mudou: a barra aparece/some imediatamente
	evaluate()
end

local function onPlayerPositionChange()
	evaluate()
end

-- Cria a janela sob demanda. No boot o map panel pode ainda nao existir,
-- entao tentamos de novo no login em vez de desativar o modulo de vez.
local function ensureWindow()
	if window then
		return true
	end

	local parent = modules.game_interface and modules.game_interface.getMapPanel()
	if not parent then
		return false
	end

	local ok, created = pcall(function()
		return g_ui.createWidget('BossBarWindow', parent)
	end)

	if not ok or not created then
		g_logger.error('[game_bossbar] nao foi possivel criar BossBarWindow: ' .. tostring(created))
		return false
	end

	window = created
	window:hide()
	return true
end

local function onGameStart()
	ensureWindow()
	evaluate()
	if not idleEvent then
		idleEvent = scheduleEvent(tickIdle, 2000)
	end
end

local function onGameEnd()
	hide()
	if idleEvent then
		removeEvent(idleEvent)
		idleEvent = nil
	end
end

-- ============================================================
-- CICLO DE VIDA
-- ============================================================

function init()
	if g_app.isMobile() then
		return
	end

	-- O .otui so declara ESTILOS, entao precisa ser importado antes de qualquer
	-- createWidget. Sem isso 'BossBarWindow' nao existe e createWidget volta nil.
	local styleOk, styleErr = pcall(function()
		g_ui.importStyle('bossbar')
	end)
	if not styleOk then
		g_logger.error('[game_bossbar] falha ao importar bossbar.otui: ' .. tostring(styleErr))
		return
	end

	-- A janela e criada por ensureWindow(), que tolera o map panel ainda nao
	-- existir no boot e tenta de novo no login. Os sinais sao conectados de
	-- qualquer forma: sem eles o modulo nunca se recuperaria.
	ensureWindow()

	connect(Creature, {
		onAppear = onCreatureAppear,
		onDisappear = onCreatureDisappear,
		onHealthPercentChange = onHealthPercentChange,
	})

	connect(LocalPlayer, {
		onPositionChange = onPlayerPositionChange,
	})

	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
		onAttackingCreatureChange = onAttackingCreatureChange,
	})

	if g_game.isOnline() then
		onGameStart()
	end
end

function terminate()
	disconnect(Creature, {
		onAppear = onCreatureAppear,
		onDisappear = onCreatureDisappear,
		onHealthPercentChange = onHealthPercentChange,
	})

	disconnect(LocalPlayer, {
		onPositionChange = onPlayerPositionChange,
	})

	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
		onAttackingCreatureChange = onAttackingCreatureChange,
	})

	if idleEvent then
		removeEvent(idleEvent)
		idleEvent = nil
	end

	if window then
		window:destroy()
		window = nil
	end

	current = nil
end
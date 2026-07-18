---------------------------
-- Lua code author: R1ck --
-- Company: VICTOR HUGO PERENHA - JOGOS ON LINE --
---------------------------

Trackers = {}
Trackers.__index = Trackers

bossTrackerWindow = nil
bestiaryTrackerWindow = nil
imbuementTrackerWindow = nil

local openWindowEvent = nil


function init()
	connect(g_game, {
		onMonsterTrackerData = Trackers.onMonsterTrackerData,
		onUpdateImbuementTracker = ImbuementTracker.onReceiveData,
		onGameStart = online,
		onGameEnd = offline
	})

	-- init boss tracker
	bossTrackerWindow = g_ui.loadUI('styles/boss_tracker', m_interface.getRightPanel())
	local scrollbar = bossTrackerWindow:getChildById('miniwindowScrollBar')
	scrollbar:mergeStyle({ ['$!on'] = { }})

	local redirectButton = bossTrackerWindow:getRedirectButton()
	redirectButton:setTooltip("Open the entry of a boss in the Bossitary to add it to this list")

	local sortButton = bossTrackerWindow:getExtraButton()
	sortButton:setTooltip("Show sort options")

	bossTrackerWindow:setup()
	bossTrackerWindow:close()

	-- init bestiary tracker
	bestiaryTrackerWindow = g_ui.loadUI('styles/bestiary_tracker', m_interface.getRightPanel())
	local scrollbar = bestiaryTrackerWindow:getChildById('miniwindowScrollBar')
	scrollbar:mergeStyle({ ['$!on'] = { }})

	local redirectButton = bestiaryTrackerWindow:getRedirectButton()
	redirectButton:setTooltip("Open the entry of a boss in the Bestiary to add it to this list")

	local sortButton = bestiaryTrackerWindow:getExtraButton()
	sortButton:setTooltip("Show sort options")

	bestiaryTrackerWindow:setup()
	bestiaryTrackerWindow:close()

	-- init imbuement tracker
	imbuementTrackerWindow = g_ui.loadUI('styles/imbui_tracker', m_interface.getRightPanel())
	local scrollbar = imbuementTrackerWindow:getChildById('miniwindowScrollBar')
	scrollbar:mergeStyle({ ['$!on'] = { }})

	local sortButton = imbuementTrackerWindow:getExtraButton()
	sortButton:setTooltip("Click here to configure the Imbuement Tracker.")

	imbuementTrackerWindow:setup()
	imbuementTrackerWindow:close()
end

function terminate()
	disconnect(g_game, {
		onMonsterTrackerData = Trackers.onMonsterTrackerData,
		onUpdateImbuementTracker = ImbuementTracker.onReceiveData,
		onGameStart = online,
		onGameEnd = offline
	})

end

function online()
	local benchmark = g_clock.millis()
	ImbuementTracker.online()
	if g_game.isOnline() then
		g_game.openBosstiaryWindow()
	end
	consoleln("Trackers loaded in " .. (g_clock.millis() - benchmark) / 1000 .. " seconds.")
end

function offline()
	ImbuementTracker.offline()
	BossTracker.resetWindow()
	if openWindowEvent then
		removeEvent(openWindowEvent)
		openWindowEvent = nil
	end
end

function Trackers.onMonsterTrackerData(trackerType, monsterData)
	if trackerType == 0 then
		BestiaryTrackerList = monsterData
		BestiaryTracker.showTrackerData()
	else
		BossTrackerList = monsterData
		BossTracker.showTrackerData()
	end
end

-- Forca o re-layout da lista de um tracker apos reconstrucao dos widgets.
-- Necessario porque UILayout descarta (nao enfileira) updates disparados
-- enquanto disableUpdates esta ativo, e porque o scrollbar da MiniWindow
-- mantem o offset antigo apos destroyChildren, empurrando os widgets novos
-- para fora da area visivel ate um minimize/maximize forcar o layout.
function Trackers.refreshTrackerLayout(window, resetScroll)
	if not window then
		return
	end

	local contents = window.contentsPanel or window:getChildById('contentsPanel')
	if contents then
		-- Replica o efeito do minimize/maximize (que comprovadamente restaura a
		-- lista): o ciclo hide/show dispara o re-layout completo dos filhos.
		-- So faz isso se a janela nao estiver minimizada (contents deve ficar
		-- oculto enquanto minimizada).
		if not window.minimized and contents:isVisible() then
			contents:hide()
			contents:show()
		end

		local layout = contents:getLayout()
		if layout and layout.update then
			layout:update()
		end
		if contents.updateLayout then
			contents:updateLayout()
		end
	end

	local scrollbar = window:getChildById('miniwindowScrollBar')
	if scrollbar and scrollbar.setValue then
		if resetScroll then
			scrollbar:setValue(0)
		elseif scrollbar.getMaximum and scrollbar.getValue then
			local maximum = scrollbar:getMaximum() or 0
			if scrollbar:getValue() > maximum then
				scrollbar:setValue(maximum)
			end
		end
	end

	if window.updateLayout then
		window:updateLayout()
	end

	-- Segundo passe no proximo frame: cobre updates que o engine descartou
	-- durante o rebuild (UILayout nao enfileira updates desabilitados).
	scheduleEvent(function()
		if not window or (window.isDestroyed and window:isDestroyed()) then
			return
		end
		local panel = window.contentsPanel or window:getChildById('contentsPanel')
		if panel then
			local panelLayout = panel:getLayout()
			if panelLayout and panelLayout.update then
				panelLayout:update()
			end
			if panel.updateLayout then
				panel:updateLayout()
			end
		end
	end, 15)
end

function toggleBossTracker()
	if bossTrackerWindow:isVisible() then
		bossTrackerWindow:close()
	else
		bossTrackerWindow:open()
		if m_interface.addToPanels(bossTrackerWindow) then
			bossTrackerWindow:getParent():moveChildToIndex(bossTrackerWindow, #bossTrackerWindow:getParent():getChildren())
			BossTracker.initSortFields()
			BossTracker.showTrackerData()
		end
	end
end

function toggleBestiaryTracker()
	if bestiaryTrackerWindow:isVisible() then
		bestiaryTrackerWindow:close()
    	modules.game_sidebuttons.setButtonVisible("bestiaryTrackerWidget", false)
	else
		bestiaryTrackerWindow:open()
		if m_interface.addToPanels(bestiaryTrackerWindow) then
			bestiaryTrackerWindow:getParent():moveChildToIndex(bestiaryTrackerWindow, #bestiaryTrackerWindow:getParent():getChildren())
			BestiaryTracker.initSortFields()
			BestiaryTracker.showTrackerData()
    		modules.game_sidebuttons.setButtonVisible("bestiaryTrackerWidget", true)
		end
	end
end

function toggleImbuementTracker()
	if imbuementTrackerWindow:isVisible() then
		imbuementTrackerWindow:close()
    	modules.game_sidebuttons.setButtonVisible("imbuementTrackerWidget", false)
		g_game.imbuementDurations(false)
	else
		imbuementTrackerWindow:open()
		if m_interface.addToPanels(imbuementTrackerWindow) then
			imbuementTrackerWindow:getParent():moveChildToIndex(imbuementTrackerWindow, #imbuementTrackerWindow:getParent():getChildren())
			ImbuementTracker.initSortFields()
			g_game.imbuementDurations(true)
			openWindowEvent = scheduleEvent(showTracker, 50)
		end
	end
end

function showTracker()
	ImbuementTracker.showTrackerData()
	modules.game_sidebuttons.setButtonVisible("imbuementTrackerWidget", true)
end

function moveTracker(type, panel, height, minimized)
  local windowByType = {
    ["bestiaryTracker"] = bestiaryTrackerWindow,
    ["bosstiaryTracker"] = bossTrackerWindow,
    ["imbuementTracker"] = imbuementTrackerWindow
  }
  local window = windowByType[type]

  window:setParent(panel)
  window:open()

  if minimized then
    window:setHeight(height)
    window:minimize()
  else
    window:maximize()
    window:setHeight(height)
  end

  if type == "imbuementTracker" then
    ImbuementTracker.initSortFields()
    g_game.doThing(false)
    g_game.imbuementDurations(true)
    g_game.doThing(true)
    if not minimized then
      openWindowEvent = scheduleEvent(showTracker, 50)
    end
  end

  return window
end

function onPlayerUnload()
	BestiaryTracker.onLogout()
	BossTracker.onLogout()
end

function onPlayerLoad(bestiaryTrackerWidgetOptions, bossTrackerWidgetOptions)
	if bestiaryTrackerWidgetOptions then
		BestiaryTracker.onLogin(bestiaryTrackerWidgetOptions)
	end

	if bossTrackerWidgetOptions then
		BossTracker.onLogin(bossTrackerWidgetOptions)
	end
end

function reopenImbuementPanel()
	if imbuementTrackerWindow:isVisible() then
		g_game.doThing(false)
		g_game.imbuementDurations(true)
		g_game.doThing(true)
	end
end

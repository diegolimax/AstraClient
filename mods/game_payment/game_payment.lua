-- Payment System :: janela de doacao (Pix / Mercado Pago / Stripe)
-- mods/game_payment/game_payment.lua
--
-- REESCRITO a partir do game_payment original (vallari), com as correcoes:
--   * URLs quebradas (init.php/init.php, init.php/stripe_status.php) -> baseUrl
--     unico + endpoints montados certo
--   * hide() com logica invertida -> corrigido
--   * polling unificado (um unico agendador para MP/Stripe/Pix)
--   * abre via opcode 0x5A vindo do servidor (!pix / !donate)
--   * sem globais vazando: tudo via env do modulo (modules.game_payment.*)
--
-- IMPORTANTE: este modulo so conversa com o SEU backend web (PHP). O servidor
-- do jogo nao participa do pagamento -- quem credita os pontos e o PHP.
-- Configure abaixo o SEU dominio e a SUA senha de API antes de usar.

PaymentConfig = {
	-- Base do backend, SEM barra no final. Os endpoints sao concatenados nela.
	baseUrl = "https://SEUSITE.com.br/payment", -- <<< TROQUE para o seu dominio
	apiPassword = "TROQUE_ESTA_SENHA", -- <<< mesma senha configurada no PHP

	pollIntervalMs = 10000, -- checa o status a cada 10s
	minValue = 1,
	maxValue = 50000, -- precisa bater com o maximum do valorSpinBox no .otui

	endpoints = {
		init = "/init.php", -- cria pagamento MP/Stripe (retorna payment_link + payment_id)
		pix = "/paymentpix.php", -- cria/consulta/cancela pagamento Pix
		history = "/history.php", -- historico de transacoes do jogador
		stripeStatus = "/stripe_status.php",
		mercadoPagoStatus = "/mercadopago_status.php",
	},

	-- Promocao de bonus por valor doado. A UI mostra o bonus para o jogador,
	-- mas QUEM CREDITA e o backend PHP -- replique a MESMA tabela la, senao
	-- o jogador ve um bonus que nao recebe. enabled = false esconde tudo.
	bonus = {
		enabled = true,
		-- aplica o maior tier cujo `min` seja <= valor doado
		tiers = {
			{ min = 10, bonus = 5 },
			{ min = 50, bonus = 30 },
			{ min = 100, bonus = 80 },
			{ min = 250, bonus = 250 },
		},
	},
}

function PaymentConfig.url(key)
	return PaymentConfig.baseUrl .. (PaymentConfig.endpoints[key] or "")
end

-- Servidor -> cliente: 0xC9 + subtype 0x00 = abrir a janela de doacao
-- NAO usar 0x5A/0x54-0x59 baixos: no protocolo 860 varios bytes baixos sao
-- opcodes NATIVOS do Tibia (0x5A = player stats). Registrar por cima deles
-- sequestra o pacote nativo e dessincroniza o stream inteiro. 0xC9 e alto e
-- livre nesta base.
local OPCODE_SERVER = 0xC9
local S2C_OPEN = 0x00

paymentWindow = nil
local historyWindow = nil
local messageBox = nil
local pollEvent = nil

-- ============================================================
-- HELPERS (compartilhados com game_pix.lua via env do modulo)
-- ============================================================

function showBox(header, text)
	if messageBox then
		messageBox:destroy()
		messageBox = nil
	end
	local function close()
		if messageBox then
			messageBox:destroy()
			messageBox = nil
		end
	end
	messageBox = displayGeneralBox(tr(header), tr(text), {
		{ text = tr("OK"), callback = close },
	}, close)
end

function stopPolling()
	if pollEvent then
		removeEvent(pollEvent)
		pollEvent = nil
	end
end

function schedulePoll(fn)
	stopPolling()
	pollEvent = scheduleEvent(fn, PaymentConfig.pollIntervalMs)
end

-- POST JSON com decodificacao e tratamento de erro num lugar so.
-- callback(response) so e chamado com a resposta ja decodificada.
function paymentPost(urlStr, payload, callback, errorMessage)
	if not HTTP or not HTTP.post or not json then
		showBox("Erro", "Este cliente foi compilado sem suporte a HTTP/JSON.")
		return false
	end

	payload.pass = PaymentConfig.apiPassword

	HTTP.post(urlStr, json.encode(payload), function(data, err)
		if err then
			showBox("Erro", errorMessage or "Erro de comunicacao com o servidor de pagamentos.")
			return
		end
		local ok, response = pcall(json.decode, data)
		if not ok or not response then
			showBox("Erro", "Resposta invalida do servidor de pagamentos.")
			return
		end
		callback(response)
	end)
	return true
end

-- ============================================================
-- POLLING DE STATUS (Mercado Pago / Stripe)
-- ============================================================

local function checkPayment(paymentId, metodo)
	if not g_game.isOnline() then
		stopPolling()
		return
	end
	if not paymentId or paymentId == "" then
		return
	end

	local endpoint
	if metodo == "STRIPE" then
		endpoint = PaymentConfig.url("stripeStatus")
	elseif metodo == "MP" then
		endpoint = PaymentConfig.url("mercadoPagoStatus")
	else
		return
	end

	paymentPost(endpoint, { payment_id = paymentId, metodo_pagamento = metodo }, function(response)
		local status = response.status
		if status == "aprovado" then
			stopPolling()
			cancelDonate()
			showBox("Aviso", "Seu pagamento foi aprovado e seus pontos adicionados!\nMuito obrigado pela sua doacao!")
		elseif status == "pendente" then
			schedulePoll(function()
				checkPayment(paymentId, metodo)
			end)
		elseif status == "cancelado" then
			stopPolling()
			cancelDonate()
			showBox("Aviso", "O pagamento foi cancelado. Nenhuma cobranca foi efetuada.")
		else
			stopPolling()
			cancelDonate()
			showBox("Erro", "Erro ao verificar o pagamento. Status desconhecido.")
		end
	end, "Erro ao verificar o pagamento. Tente novamente.")
end

-- ============================================================
-- CRIACAO DE PAGAMENTO (Mercado Pago / Stripe)
-- ============================================================

local function sendPost(valor, playerAccount, playerCharacter, metodo, moeda)
	if not valor or valor < PaymentConfig.minValue then
		return
	end
	if metodo == "MP" then
		moeda = "brl"
	end

	paymentPost(PaymentConfig.url("init"), {
		nameAccount = playerAccount,
		namePlayer = playerCharacter,
		valor = valor,
		metodo_pagamento = metodo,
		currency = moeda,
	}, function(response)
		if response.payment_link and response.payment_id then
			g_platform.openUrl(response.payment_link)
			checkPayment(response.payment_id, metodo)
		else
			showBox("Erro", response.message or "Erro ao iniciar o pagamento.")
		end
	end, "Ocorreu um erro na transacao.")
end

-- ============================================================
-- HISTORICO
-- ============================================================

local STATUS_COLORS = {
	aprovado = "#0af20a",
	pendente = "#dff20a",
	cancelado = "#d40d06",
}

function fetchTransactionHistory()
	local playerName = g_game.getCharacterName()
	if not playerName or playerName == "" then
		showBox("Erro", "Nome do jogador nao encontrado.")
		return
	end

	paymentPost(PaymentConfig.url("history"), { player_name = playerName }, function(response)
		if response.transactions and #response.transactions > 0 then
			showTransactionHistory(response.transactions)
		else
			showBox("Aviso", "Nenhum historico de transacao encontrado.")
		end
	end, "Nao foi possivel obter o historico de transacao.")
end

local function addHistoryLabel(row, id, text, width, marginLeft)
	local label = g_ui.createWidget("Label", row)
	label:setId(id)
	label:setText(text)
	label:setWidth(width)
	label:addAnchor(AnchorLeft, "parent", AnchorLeft)
	label:addAnchor(AnchorVerticalCenter, "parent", AnchorVerticalCenter)
	label:setMarginLeft(marginLeft)
	return label
end

function showTransactionHistory(transactions)
	if not historyWindow then
		historyWindow = g_ui.displayUI("game_history")
		if not historyWindow then
			return
		end
		historyWindow:hide()
	end

	local transactionList = historyWindow:getChildById("transactionList")
	if not transactionList then
		return
	end
	transactionList:destroyChildren()

	for _, transaction in ipairs(transactions or {}) do
		local row = g_ui.createWidget("FlatPanel", transactionList)
		row:setHeight(25)

		addHistoryLabel(row, "emissionLabel", transaction.date or "N/A", 120, 10)
		addHistoryLabel(row, "pointsLabel", tostring(transaction.pontos or 0), 50, 170)
		addHistoryLabel(row, "valueLabel",
			string.format("R$ %.2f", tonumber(transaction.valor) or 0), 100, 250)
		addHistoryLabel(row, "methodLabel", transaction.metodo_pagamento or "N/A", 100, 365)

		local statusLabel = addHistoryLabel(row, "statusLabel", transaction.status or "N/A", 100, 460)
		statusLabel:setColor(STATUS_COLORS[transaction.status] or "#ffffff")
	end

	historyWindow:show()
	historyWindow:raise()
	historyWindow:focus()
end

function closeHistory()
	if historyWindow then
		historyWindow:hide()
	end
end

-- ============================================================
-- BONUS DA PROMOCAO
-- ============================================================

local function bonusFor(valor)
	local config = PaymentConfig.bonus
	if not config or not config.enabled then
		return 0
	end
	local best = 0
	for _, tier in ipairs(config.tiers or {}) do
		if valor >= tier.min and tier.bonus > best then
			best = tier.bonus
		end
	end
	return best
end

-- Le o valor digitado, sem reescrever o campo enquanto o jogador digita.
-- clamp = true normaliza (usado so na hora de confirmar).
local function getDonateValue(clamp)
	if not paymentWindow then
		return 0
	end
	local input = paymentWindow:getChildById("valorInput")
	if not input then
		return 0
	end

	local valor = math.floor(tonumber(input:getText()) or 0)
	if clamp then
		if valor < PaymentConfig.minValue then
			valor = 0 -- invalido: quem chamou decide a mensagem
		elseif valor > PaymentConfig.maxValue then
			valor = PaymentConfig.maxValue
			input:setText(tostring(valor))
		end
	end
	return valor
end

function updateBonusLabel()
	if not paymentWindow then
		return
	end
	local label = paymentWindow:getChildById("bonusLabel")
	if not label then
		return
	end

	local config = PaymentConfig.bonus
	if not config or not config.enabled then
		label:setText("")
		return
	end

	local valor = getDonateValue(false)
	local bonus = bonusFor(valor)

	if bonus > 0 then
		label:setText(("Bonus da promocao: +%d pontos!"):format(bonus))
		label:setColor("#ffd700")
		return
	end

	-- sem bonus no valor atual: mostra o proximo tier como incentivo
	local nextTier
	for _, tier in ipairs(config.tiers or {}) do
		if valor < tier.min and (not nextTier or tier.min < nextTier.min) then
			nextTier = tier
		end
	end
	if nextTier then
		label:setText(("Doe R$ %d ou mais e ganhe +%d de bonus!"):format(nextTier.min, nextTier.bonus))
		label:setColor("#afafaf")
	else
		label:setText("")
	end
end

-- ============================================================
-- JANELA PRINCIPAL
-- ============================================================

function updatePaymentImage()
	local combo = paymentWindow:getChildById("paymentMethodComboBox")
	local image = paymentWindow:getChildById("paymentImage")
	local method = combo:getCurrentOption().text:lower()

	if method == "pix" then
		image:setImageSource("imagens/payment_pix.png")
	elseif method == "mercado pago" then
		image:setImageSource("imagens/payment_mercadopago.png")
	elseif method == "stripe" then
		image:setImageSource("imagens/payment_stripe.png")
	else
		image:clearImage()
	end
end

function toggleCurrencySelection()
	local combo = paymentWindow:getChildById("paymentMethodComboBox")
	local currency = paymentWindow:getChildById("currencyComboBox")
	local method = combo:getCurrentOption().text:lower()

	-- Pix e Mercado Pago sao sempre BRL; moeda livre so no Stripe
	if method == "mercado pago" or method == "pix" then
		currency:setCurrentOption("BRL")
		currency:disable()
		currency:setTooltip("Moeda fixa: BRL (Real)")
	else
		currency:enable()
		currency:setTooltip("")
	end
end

function sendDonate()
	local valor = getDonateValue(true)
	if valor < PaymentConfig.minValue then
		showBox("Aviso", ("Voce precisa doar um valor minimo de %d real."):format(PaymentConfig.minValue))
		return
	end

	local metodo = paymentWindow:getChildById("paymentMethodComboBox"):getCurrentOption().text:lower()
	local moeda = paymentWindow:getChildById("currencyComboBox"):getCurrentOption().text:lower()
	local playerAccount = G.account or ""
	local playerCharacter = g_game.getCharacterName()

	if metodo == "mercado pago" then
		sendPost(valor, playerAccount, playerCharacter, "MP")
	elseif metodo == "stripe" then
		sendPost(valor, playerAccount, playerCharacter, "STRIPE", moeda)
	elseif metodo == "pix" then
		Pix.sendPost(valor, playerAccount, playerCharacter)
	else
		showBox("Erro", "Metodo de pagamento invalido selecionado.")
	end
end

function cancelDonate()
	if paymentWindow and paymentWindow:isVisible() then
		paymentWindow:hide()
	end
	if messageBox then
		messageBox:destroy()
		messageBox = nil
	end
end

function show()
	if not paymentWindow then
		return
	end
	paymentWindow:show()
	paymentWindow:raise()
	paymentWindow:focus()
end

function hide()
	if paymentWindow then
		paymentWindow:hide()
	end
end

function toggle()
	if not paymentWindow then
		return
	end
	if paymentWindow:isVisible() then
		hide()
		stopPolling()
	else
		show()
	end
end

-- ============================================================
-- OPCODE 0x5A (!pix / !donate no servidor abre a janela)
-- ============================================================

local function onPaymentOpcode(protocol, msg)
	local subtype = msg:getU8()
	if subtype == S2C_OPEN then
		show()
	end
end

local function onGameStart()
	ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	ProtocolGame.registerOpcode(OPCODE_SERVER, onPaymentOpcode)
end

local function onGameEnd()
	stopPolling()
	cancelDonate()
end

-- ============================================================
-- CICLO DE VIDA
-- ============================================================

function init()
	-- CRITICO: registra o opcode ANTES de tocar na UI. Se a UI falhar
	-- (ex: pasta imagens/ ausente), o opcode ja esta registrado.
	connect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})
	onGameStart()

	if not HTTP or not HTTP.post then
		g_logger.warning("[game_payment] HTTP indisponivel neste cliente; doacoes nao vao funcionar.")
	end
	if not json then
		g_logger.warning("[game_payment] json indisponivel neste cliente; doacoes nao vao funcionar.")
	end

	-- UI isolada em pcall: qualquer erro aqui NAO pode impedir o registro do
	-- opcode acima nem derrubar o modulo inteiro.
	local ok, err = pcall(function()
		paymentWindow = g_ui.displayUI("game_payment")
		paymentWindow:hide()

		local combo = paymentWindow:getChildById("paymentMethodComboBox")
		combo:addOption("Pix")
		combo:addOption("Mercado Pago")
		combo:addOption("Stripe")
		function combo.onOptionChange()
			toggleCurrencySelection()
			updatePaymentImage()
		end

		local currency = paymentWindow:getChildById("currencyComboBox")
		currency:addOption("BRL")
		currency:addOption("USD")
		currency:addOption("EUR")

		-- Campo de valor: TextEdit numerico puro. NADA reescreve o texto
		-- enquanto o jogador digita; a validacao acontece so no CONFIRMAR.
		local input = paymentWindow:getChildById("valorInput")
		function input.onTextChange()
			updateBonusLabel()
		end

		toggleCurrencySelection()
		updatePaymentImage()
		updateBonusLabel()
	end)

	if not ok then
		g_logger.error("[game_payment] falha ao montar a UI (a janela nao vai abrir, mas o resto do cliente segue normal): " .. tostring(err))
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = onGameStart,
		onGameEnd = onGameEnd,
	})

	if g_game.isOnline() then
		ProtocolGame.unregisterOpcode(OPCODE_SERVER)
	end

	stopPolling()

	if messageBox then
		messageBox:destroy()
		messageBox = nil
	end
	if historyWindow then
		historyWindow:destroy()
		historyWindow = nil
	end
	if paymentWindow then
		paymentWindow:destroy()
		paymentWindow = nil
	end
end

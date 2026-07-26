-- Payment System :: fluxo Pix (QR code + copia e cola)
-- mods/game_payment/game_pix.lua
--
-- Usa PaymentConfig, showBox, stopPolling, schedulePoll e cancelDonate do
-- game_payment.lua (mesmo sandbox do modulo). Fluxo:
--   1. Pix.sendPost cria o pagamento no backend -> recebe qr_code_base64,
--      qr_code (copia e cola) e payment_id
--   2. Mostra a janela do QR; clique no QR (ou no botao) copia o codigo
--   3. Faz polling do status ate aprovar/cancelar

local qrCodeWindow = nil
local currentPaymentId = nil
local currentCopiaCola = nil

Pix = {}

local function destroyQrWindow()
	if qrCodeWindow then
		qrCodeWindow:destroy()
		qrCodeWindow = nil
	end
end

local function setLoading(visible)
	if not qrCodeWindow then
		return
	end
	local loading = qrCodeWindow:getChildById("Loading")
	if loading then
		loading:setVisible(visible)
	end
end

-- ============================================================
-- POLLING DO STATUS
-- ============================================================

function Pix.checkPayment(paymentId)
	if not g_game.isOnline() then
		stopPolling()
		return
	end
	if not paymentId or paymentId == "" then
		return
	end

	paymentPost(PaymentConfig.url("pix"), { payment_id = paymentId }, function(response)
		local status = response.status
		if status == "aprovado" then
			stopPolling()
			destroyQrWindow()
			cancelDonate()
			showBox("Aviso", "Seu pagamento foi confirmado e seus pontos adicionados!\nMuito obrigado pela sua doacao!")
		elseif status == "pendente" then
			setLoading(true)
			schedulePoll(function()
				Pix.checkPayment(paymentId)
			end)
		elseif status == "cancelado" then
			stopPolling()
			destroyQrWindow()
			cancelDonate()
			showBox("Aviso", "O pagamento foi cancelado. Nenhuma cobranca foi efetuada.")
		else
			stopPolling()
			destroyQrWindow()
			cancelDonate()
			showBox("Erro", "Erro ao verificar o pagamento. Status desconhecido.")
		end
	end, "Erro ao verificar o pagamento. Tente novamente.")
end

-- ============================================================
-- CRIACAO DO PAGAMENTO / QR
-- ============================================================

local function showQr(response)
	local base64 = response.qr_code_base64
	local copiaecola = response.qr_code
	local paymentId = response.payment_id

	if not base64 or not copiaecola or not paymentId then
		showBox("Aviso", "Dados incompletos na transacao. Tente novamente mais tarde.")
		return
	end

	currentPaymentId = paymentId
	currentCopiaCola = copiaecola

	if not qrCodeWindow then
		qrCodeWindow = g_ui.displayUI("qrcodePix")
	end

	local qrCode = qrCodeWindow:getChildById("qrCode")

	-- setImageSourceBase64 pode nao existir em builds antigas; sem ele, o
	-- jogador ainda paga normalmente pelo botao de copia e cola.
	local ok = pcall(function()
		qrCode:setImageSourceBase64(base64)
	end)
	if not ok then
		g_logger.warning("[game_payment] setImageSourceBase64 indisponivel; usando so copia e cola.")
		qrCode:setText("QR indisponivel.\nUse o botao Copiar abaixo.")
	end

	setLoading(false)
	qrCodeWindow:show()
	qrCodeWindow:raise()
	qrCodeWindow:focus()

	Pix.checkPayment(paymentId)
end

function Pix.sendPost(valor, playerAccount, playerCharacter)
	valor = tonumber(valor)
	if not valor or valor < PaymentConfig.minValue then
		showBox("Erro", "Valor invalido.")
		return
	end

	paymentPost(PaymentConfig.url("pix"), {
		metodo_pagamento = "PIX",
		nameAccount = playerAccount,
		namePlayer = playerCharacter,
		valor = valor,
	}, function(response)
		showQr(response)
	end, "Erro ao iniciar pagamento Pix.")
end

-- ============================================================
-- ACOES DA JANELA (chamadas pelo qrcodePix.otui)
-- ============================================================

function copyPixCode()
	if not currentCopiaCola or currentCopiaCola == "" then
		showBox("Erro", "Nenhum codigo Pix ativo.")
		return
	end
	g_window.setClipboardText(currentCopiaCola)
	showBox("Aviso", "Codigo Pix copiado para a area de transferencia.")
end

function onCancelPix()
	setLoading(true)
	stopPolling()

	if not currentPaymentId or currentPaymentId == "" then
		destroyQrWindow()
		showBox("Erro", "Nenhuma transacao ativa para cancelar.")
		return
	end

	paymentPost(PaymentConfig.url("pix"), {
		cancel_pix = true,
		payment_id = currentPaymentId,
	}, function(response)
		setLoading(false)
		if response.status == "cancelado" then
			destroyQrWindow()
			currentPaymentId = nil
			currentCopiaCola = nil
			showBox("Aviso", "A transacao foi cancelada com sucesso.")
		else
			showBox("Erro", response.message or "Erro ao cancelar a transacao.")
		end
	end, "Erro ao comunicar-se com a API para cancelar a transacao.")
end

-- ============================================================
-- CICLO DE VIDA
-- ============================================================

function pixInit()
end

function pixTerminate()
	stopPolling()
	destroyQrWindow()
	currentPaymentId = nil
	currentCopiaCola = nil
end

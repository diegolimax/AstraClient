-- =========================================================================
-- Collect All (reward chest)
--
-- O menu de contexto em modules/game_interface/gameinterface.lua (linha ~1431)
-- chama g_game.requestCollectAll(pos, itemId, stackPos), mas essa funcao nao
-- existe no client: nao esta bindada no C++ nem definida em Lua. Este mod so
-- define a funcao e manda o aviso para o servidor via extended opcode.
--
-- Toda a logica de mover os itens para o gold/loot pouch fica no servidor, em
-- data/scripts/network/reward_collect_all.lua
--
-- IMPORTANTE: COLLECT_ALL_OPCODE tem que ser o mesmo numero nos dois arquivos.
-- O 145 ja esta em uso pela blacklist do item_loot_seller.lua.
-- =========================================================================

COLLECT_ALL_OPCODE = 147

function init()
  g_game.requestCollectAll = function(pos, itemId, stackPos)
    local protocolGame = g_game.getProtocolGame()
    if not protocolGame then
      return
    end

    pos = pos or {x = 0, y = 0, z = 0}

    -- A posicao vai junto so como informacao: o servidor resolve o bau pelo
    -- proprio jogador (player:getRewardChest()), evitando o problema de
    -- client id != server id no protocolo 8.60.
    local payload = json.encode({
      x = pos.x or 0,
      y = pos.y or 0,
      z = pos.z or 0,
      itemId = itemId or 0,
      stackPos = stackPos or 0
    })

    protocolGame:sendExtendedOpcode(COLLECT_ALL_OPCODE, payload)
  end
end

function terminate()
  g_game.requestCollectAll = nil
end

import React, { useState, useEffect } from 'react';
import {
  ChatMessage,
  DisputeDecision,
  SupportTicket,
  TicketPriority,
  TicketState,
} from './types';
import { SupportApiService } from './services/supportApiService';

export const SupportAgentConsole: React.FC = () => {
  // Estado de dados
  const [tickets, setTickets] = useState<SupportTicket[]>([]);
  const [selectedTicketId, setSelectedTicketId] = useState<string>('');
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error' | 'info'; message: string } | null>(null);

  // Perfil do operador de suporte autenticado (Simulação: Agente Base vs Supervisor)
  const [currentUserRole, setCurrentUserRole] = useState<'AGENTE_BASE' | 'SUPERVISOR'>('AGENTE_BASE');

  // Chat do Painel Central
  const [newChatMessage, setNewChatMessage] = useState<string>('');

  // Formulário de Resolução do Painel Direito (RN-106, RN-141)
  const [decisao, setDecisao] = useState<DisputeDecision>('Procedente_Cliente');
  const [motivoJustificacao, setMotivoJustificacao] = useState<string>('');
  const [compensacaoValorKz, setCompensacaoValorKz] = useState<number>(0);
  const [supervisorPin, setSupervisorPin] = useState<string>('');
  const [isSupervisorAuthorized, setIsSupervisorAuthorized] = useState<boolean>(false);
  const [isSubmittingResolution, setIsSubmittingResolution] = useState<boolean>(false);

  // Filtros de Tickets
  const [filterPriority, setFilterPriority] = useState<string>('TODAS');
  const [filterState, setFilterState] = useState<string>('TODOS');

  // Limite regulamentar da alçada do Agente Base (RN-106: 3.000 Kz)
  const LIMITE_ALCADA_AGENTE_KZ = 3000;
  const PIN_SUPERVISOR_CORRETO = '9988'; // PIN padrão de homologação

  // Carregamento dos tickets e timer vivo do SLA de 5 min (RN-139)
  useEffect(() => {
    loadTickets();
  }, []);

  // Timer vivo que decresce o SLA em tempo real
  useEffect(() => {
    const timer = setInterval(() => {
      setTickets((prev) =>
        prev.map((t) => {
          if (t.estado !== 'RESOLVIDO' && t.tempoRestanteSlaSegundos > 0) {
            return { ...t, tempoRestanteSlaSegundos: t.tempoRestanteSlaSegundos - 1 };
          }
          return t;
        })
      );
    }, 1000);

    return () => clearInterval(timer);
  }, []);

  const loadTickets = async () => {
    setIsLoading(true);
    const data = await SupportApiService.getActiveTickets();
    setTickets(data);
    if (data.length > 0) {
      setSelectedTicketId(data[0].id);
      preencherFormularioComTicket(data[0]);
    }
    setIsLoading(false);
  };

  const preencherFormularioComTicket = (ticket: SupportTicket) => {
    if (ticket.decisaoResolucao) {
      setDecisao(ticket.decisaoResolucao.decisao);
      setMotivoJustificacao(ticket.decisaoResolucao.motivoJustificacao);
      setCompensacaoValorKz(ticket.decisaoResolucao.compensacaoValorKz);
    } else {
      setDecisao('Procedente_Cliente');
      setMotivoJustificacao('');
      setCompensacaoValorKz(ticket.tipoIncidente === 'REACAO_ALERGICA' ? 5000 : 2000);
      setSupervisorPin('');
      setIsSupervisorAuthorized(false);
    }
  };

  const selectedTicket = tickets.find((t) => t.id === selectedTicketId) || tickets[0];

  const handleSelectTicket = (t: SupportTicket) => {
    setSelectedTicketId(t.id);
    preencherFormularioComTicket(t);
  };

  // Envio de Mensagem no Chat
  const handleSendChatMessage = async () => {
    if (!newChatMessage.trim() || !selectedTicket) return;
    const msg = await SupportApiService.sendChatMessage(selectedTicket.id, newChatMessage);

    setTickets((prev) =>
      prev.map((t) => (t.id === selectedTicket.id ? { ...t, mensagensChat: [...t.mensagensChat, msg] } : t))
    );
    setNewChatMessage('');
  };

  // Verificação lógica do limite de compensação (RN-106)
  const isValorExcedido = compensacaoValorKz > LIMITE_ALCADA_AGENTE_KZ;
  const isBloqueadoPorAlcada =
    currentUserRole === 'AGENTE_BASE' && isValorExcedido && !isSupervisorAuthorized;

  // Verificação do PIN de Supervisor
  const handleVerifySupervisorPin = (pinValue: string) => {
    setSupervisorPin(pinValue);
    if (pinValue === PIN_SUPERVISOR_CORRETO) {
      setIsSupervisorAuthorized(true);
      setFeedback({ type: 'success', message: 'PIN de Supervisor autorizado com sucesso (Alçada desbloqueada)!' });
    } else if (pinValue.length >= 4) {
      setIsSupervisorAuthorized(false);
      setFeedback({ type: 'error', message: 'PIN de Supervisor inválido. Introduza o código correto.' });
    }
  };

  // Submissão da Resolução Formal (RN-106, RN-141, RN-142)
  const handleSubmitResolution = async () => {
    if (!selectedTicket) return;
    if (!motivoJustificacao.trim() || motivoJustificacao.length < 10) {
      setFeedback({
        type: 'error',
        message: 'RN-142: A fundamentação circunstanciada é obrigatória para auditoria (mínimo 10 caracteres).',
      });
      return;
    }

    if (isBloqueadoPorAlcada) {
      setFeedback({
        type: 'error',
        message: 'RN-106: Valor superior a 3.000 Kz. Introduza o PIN de autorização de um Supervisor.',
      });
      return;
    }

    setIsSubmittingResolution(true);

    const res = await SupportApiService.resolveDispute({
      pedidoId: selectedTicket.pedidoId,
      ticketId: selectedTicket.id,
      decisao,
      motivoJustificacao,
      compensacaoValorCentimos: Math.round(compensacaoValorKz * 100), // Converte para cêntimos inteiros (RN-059)
      supervisorAprovadorPin: isSupervisorAuthorized ? supervisorPin : undefined,
    });

    setIsSubmittingResolution(false);

    if (res.sucesso) {
      setTickets((prev) =>
        prev.map((t) =>
          t.id === selectedTicket.id
            ? {
                ...t,
                estado: 'RESOLVIDO',
                decisaoResolucao: {
                  decisao,
                  motivoJustificacao,
                  compensacaoValorKz,
                  autorEmail: currentUserRole === 'SUPERVISOR' ? 'supervisor@delivery.ao' : 'agente_base@delivery.ao',
                  supervisorAprovadorEmail: isSupervisorAuthorized ? 'supervisor_chefe@delivery.ao' : undefined,
                  resolvidoEm: new Date().toISOString().replace('T', ' ').substring(0, 19),
                },
              }
            : t
        )
      );
      setFeedback({ type: 'success', message: res.mensagem });
    } else {
      setFeedback({ type: 'error', message: res.mensagem });
    }
  };

  // Formatação de Segundos em MM:SS
  const formatSlaTimer = (seconds: number) => {
    if (seconds <= 0) return '00:00 (SLA Expirado)';
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  };

  // Filtragem da Lista de Tickets
  const filteredTickets = tickets.filter((t) => {
    const matchesPriority = filterPriority === 'TODAS' || t.prioridade === filterPriority;
    const matchesState = filterState === 'TODOS' || t.estado === filterState;
    return matchesPriority && matchesState;
  });

  return (
    <div className="h-screen flex flex-col bg-slate-900 text-slate-100 font-sans antialiased selection:bg-rose-600 selection:text-white overflow-hidden">
      {/* Barra Superior da Consola */}
      <header className="bg-slate-950 border-b border-slate-800 px-6 py-3 flex items-center justify-between shrink-0">
        <div className="flex items-center space-x-3">
          <div className="w-9 h-9 rounded-xl bg-gradient-to-tr from-rose-600 to-amber-600 flex items-center justify-center text-white font-black text-lg shadow-md">
            🎧
          </div>
          <div>
            <div className="flex items-center space-x-2">
              <h1 className="text-sm font-black tracking-tight text-white uppercase">SupportAgentConsole</h1>
              <span className="px-2 py-0.5 rounded text-[10px] font-bold bg-emerald-500/20 text-emerald-300 border border-emerald-500/30">
                Helpdesk & CRM (6.15)
              </span>
            </div>
            <p className="text-[11px] text-slate-400">
              Mediação de Conflitos, Incidentes de Segurança Alimentar (RN-139/140) e Alçadas (RN-106)
            </p>
          </div>
        </div>

        {/* Seletor de Perfil do Operador (Simulação de Perfil) */}
        <div className="flex items-center space-x-4 text-xs">
          <div className="flex items-center space-x-2 bg-slate-900 px-3 py-1.5 rounded-xl border border-slate-800">
            <span className="text-slate-400 font-semibold">Perfil Atual:</span>
            <button
              onClick={() => {
                setCurrentUserRole('AGENTE_BASE');
                setIsSupervisorAuthorized(false);
              }}
              className={`px-2 py-1 rounded font-bold transition ${
                currentUserRole === 'AGENTE_BASE'
                  ? 'bg-blue-600 text-white shadow'
                  : 'text-slate-400 hover:text-white'
              }`}
            >
              Agente Base (Alçada 3.000 Kz)
            </button>
            <button
              onClick={() => {
                setCurrentUserRole('SUPERVISOR');
                setIsSupervisorAuthorized(true);
              }}
              className={`px-2 py-1 rounded font-bold transition ${
                currentUserRole === 'SUPERVISOR'
                  ? 'bg-amber-600 text-white shadow'
                  : 'text-slate-400 hover:text-white'
              }`}
            >
              Supervisor (Sem Teto)
            </button>
          </div>

          <button
            onClick={loadTickets}
            title="Recarregar Tickets"
            className="p-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 transition"
          >
            🔄
          </button>
        </div>
      </header>

      {/* Notificação Flutuante */}
      {feedback && (
        <div className="px-6 py-2 shrink-0">
          <div
            className={`p-2.5 rounded-xl flex items-center justify-between text-xs font-semibold ${
              feedback.type === 'success'
                ? 'bg-emerald-950 border border-emerald-700 text-emerald-200'
                : feedback.type === 'error'
                ? 'bg-rose-950 border border-rose-700 text-rose-200'
                : 'bg-blue-950 border border-blue-700 text-blue-200'
            }`}
          >
            <span>{feedback.message}</span>
            <button onClick={() => setFeedback(null)} className="underline hover:opacity-80">
              ✕
            </button>
          </div>
        </div>
      )}

      {/* ==================================================================== */}
      {/* ESTRUTURA VERTICAL INTEGRADA DE TRÊS PAINÉIS (3-COLUMN CRM)          */}
      {/* ==================================================================== */}
      <div className="flex-1 grid grid-cols-12 overflow-hidden">
        {/* ------------------------------------------------------------------ */}
        {/* PAINEL ESQUERDO: LISTA DE TICKETS E FILA PRIORITÁRIA (RN-139)      */}
        {/* ------------------------------------------------------------------ */}
        <aside className="col-span-3 border-r border-slate-800 bg-slate-950 flex flex-col overflow-hidden">
          {/* Header e Filtros da Fila */}
          <div className="p-3.5 border-b border-slate-800 space-y-2.5 shrink-0">
            <div className="flex items-center justify-between">
              <span className="text-xs font-bold text-slate-200 uppercase tracking-wider">
                Fila de Incidentes ({filteredTickets.length})
              </span>
              <span className="text-[10px] font-mono bg-rose-950 text-rose-300 border border-rose-800 px-2 py-0.5 rounded font-bold">
                SLA Crítico &lt; 5 min
              </span>
            </div>

            <div className="grid grid-cols-2 gap-2 text-[11px]">
              <select
                value={filterPriority}
                onChange={(e) => setFilterPriority(e.target.value)}
                className="bg-slate-900 border border-slate-700 rounded-lg p-1.5 text-slate-200 font-bold focus:outline-none"
              >
                <option value="TODAS">Prioridade: Todas</option>
                <option value="CRITICA">Crítica (RN-140)</option>
                <option value="ALTA">Alta</option>
                <option value="MEDIA">Média</option>
                <option value="BAIXA">Baixa</option>
              </select>

              <select
                value={filterState}
                onChange={(e) => setFilterState(e.target.value)}
                className="bg-slate-900 border border-slate-700 rounded-lg p-1.5 text-slate-200 font-bold focus:outline-none"
              >
                <option value="TODOS">Estado: Todos</option>
                <option value="ABERTO">Aberto</option>
                <option value="EM_ANALISE">Em Análise</option>
                <option value="RESOLVIDO">Resolvido</option>
              </select>
            </div>
          </div>

          {/* Lista com Rolagem */}
          <div className="flex-1 overflow-y-auto divide-y divide-slate-800/60 p-2 space-y-2">
            {filteredTickets.map((t) => {
              const isSelected = t.id === selectedTicket?.id;
              const isCriticalSafety = t.tipoIncidente === 'REACAO_ALERGICA' || t.prioridade === 'CRITICA';
              const isResolved = t.estado === 'RESOLVIDO';

              return (
                <div
                  key={t.id}
                  onClick={() => handleSelectTicket(t)}
                  className={`p-3 rounded-xl border cursor-pointer transition ${
                    isSelected
                      ? 'bg-slate-900 border-rose-500 shadow-md ring-1 ring-rose-500/50'
                      : 'bg-slate-950 border-slate-800/80 hover:bg-slate-900/60 hover:border-slate-700'
                  }`}
                >
                  <div className="flex items-start justify-between">
                    <span className="font-mono text-xs font-bold text-white">{t.codigoDisplay}</span>
                    <div className="flex items-center space-x-1">
                      {isResolved ? (
                        <span className="px-1.5 py-0.2 rounded text-[10px] font-bold bg-emerald-950 text-emerald-300 border border-emerald-800">
                          RESOLVIDO
                        </span>
                      ) : isCriticalSafety ? (
                        <span className="px-1.5 py-0.2 rounded text-[10px] font-bold bg-rose-600 text-white animate-pulse">
                          🚨 CRÍTICA (RN-140)
                        </span>
                      ) : (
                        <span className="px-1.5 py-0.2 rounded text-[10px] font-bold bg-slate-800 text-slate-300">
                          {t.prioridade}
                        </span>
                      )}
                    </div>
                  </div>

                  <p className="text-xs font-bold text-slate-200 mt-1 line-clamp-1">{t.lojaNome}</p>
                  <p className="text-[11px] text-slate-400 mt-0.5 line-clamp-2">{t.motivoAbertura}</p>

                  <div className="mt-2.5 pt-2 border-t border-slate-800/60 flex items-center justify-between text-[10px] font-mono">
                    <span className="text-slate-400">{t.clienteNome.split(' ')[0]}</span>
                    {!isResolved && (
                      <span
                        className={`font-bold flex items-center space-x-1 ${
                          t.tempoRestanteSlaSegundos < 180 ? 'text-rose-400 animate-pulse' : 'text-amber-400'
                        }`}
                      >
                        <span>⏱</span>
                        <span>{formatSlaTimer(t.tempoRestanteSlaSegundos)}</span>
                      </span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </aside>

        {/* ------------------------------------------------------------------ */}
        {/* PAINEL CENTRAL: FOCO DO PEDIDO, TIMELINE E CHAT (RN-138, RN-101)   */}
        {/* ------------------------------------------------------------------ */}
        <section className="col-span-5 border-r border-slate-800 bg-slate-900 flex flex-col overflow-hidden">
          {selectedTicket ? (
            <>
              {/* Cabeçalho do Pedido e Máquina de Estados */}
              <div className="p-4 bg-slate-950 border-b border-slate-800 shrink-0 space-y-3">
                <div className="flex items-start justify-between">
                  <div>
                    <div className="flex items-center space-x-2">
                      <span className="text-base font-black text-white font-mono">{selectedTicket.codigoDisplay}</span>
                      <span className="text-xs font-bold text-slate-400">({selectedTicket.tipoIncidente})</span>
                    </div>
                    <p className="text-xs text-slate-300 font-semibold mt-0.5">{selectedTicket.lojaNome} • NIF: {selectedTicket.lojaNif}</p>
                    <p className="text-[11px] text-slate-400">
                      Cliente: <strong className="text-slate-200">{selectedTicket.clienteNome}</strong> ({selectedTicket.clienteTelemovelMascarado})
                    </p>
                  </div>
                  <div className="text-right">
                    <span className="text-sm font-bold text-emerald-400 font-mono block">
                      {selectedTicket.totalKz.toLocaleString()} Kz
                    </span>
                    <span className="text-[10px] text-slate-400 block">{selectedTicket.itensResumo}</span>
                  </div>
                </div>

                {/* Linha do Tempo dos Estados do Pedido */}
                <div className="pt-2 border-t border-slate-800/80">
                  <span className="text-[10px] uppercase font-bold text-slate-400 block mb-1">
                    Timeline da Máquina de Estados (OMS):
                  </span>
                  <div className="flex items-center space-x-2 text-[10px] font-mono overflow-x-auto pb-1">
                    {selectedTicket.timelinePedido.map((step, idx) => (
                      <div key={idx} className="flex items-center space-x-1 shrink-0">
                        <span className="w-2 h-2 rounded-full bg-emerald-500" />
                        <span className="font-bold text-slate-200">{step.estado}</span>
                        <span className="text-slate-500">({step.timestamp})</span>
                        {idx < selectedTicket.timelinePedido.length - 1 && <span className="text-slate-600">→</span>}
                      </div>
                    ))}
                  </div>
                </div>
              </div>

              {/* Galeria de Fotos de Evidências (RN-101 - Dano/Derrame/Alergénios) */}
              {selectedTicket.evidenciasFotos.length > 0 && (
                <div className="p-3 bg-slate-950/60 border-b border-slate-800 shrink-0">
                  <span className="text-[10px] font-bold uppercase tracking-wider text-amber-400 block mb-2">
                    Evidências Fotográficas Submetidas (RN-101):
                  </span>
                  <div className="flex items-center space-x-3 overflow-x-auto">
                    {selectedTicket.evidenciasFotos.map((foto) => (
                      <div key={foto.id} className="relative group shrink-0 rounded-xl overflow-hidden border border-slate-700">
                        <img src={foto.url} alt={foto.legenda} className="w-24 h-16 object-cover" />
                        <div className="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition flex items-center justify-center p-1 text-[9px] text-white text-center">
                          {foto.legenda}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Chat Central de Mediação com Mascaramento */}
              <div className="flex-1 overflow-y-auto p-4 space-y-3">
                {selectedTicket.mensagensChat.map((msg) => {
                  const isSupport = msg.remetenteTipo === 'SUPORTE';
                  const isSystem = msg.remetenteTipo === 'SISTEMA';
                  const isClient = msg.remetenteTipo === 'CLIENTE';

                  return (
                    <div
                      key={msg.id}
                      className={`flex flex-col ${isSupport ? 'items-end' : isSystem ? 'items-center' : 'items-start'}`}
                    >
                      <div className="flex items-center space-x-1.5 text-[10px] text-slate-400 mb-1">
                        <span className="font-bold text-slate-300">{msg.remetenteNome}</span>
                        <span>•</span>
                        <span>{msg.timestamp}</span>
                      </div>

                      <div
                        className={`p-3 rounded-2xl max-w-md text-xs leading-relaxed ${
                          isSupport
                            ? 'bg-rose-600 text-white rounded-tr-none shadow-md'
                            : isSystem
                            ? 'bg-slate-950 border border-slate-800 text-amber-300 text-center font-mono text-[11px]'
                            : isClient
                            ? 'bg-slate-800 text-slate-100 rounded-tl-none border border-slate-700'
                            : 'bg-slate-800/80 text-slate-200 border border-slate-700'
                        }`}
                      >
                        {msg.conteudo}
                      </div>
                    </div>
                  );
                })}
              </div>

              {/* Input de Envio de Mensagem no Chat */}
              <div className="p-3 bg-slate-950 border-t border-slate-800 shrink-0 flex items-center space-x-2">
                <input
                  type="text"
                  value={newChatMessage}
                  onChange={(e) => setNewChatMessage(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') handleSendChatMessage();
                  }}
                  placeholder="Escrever resposta oficial do suporte (mascaramento ativo)..."
                  className="bg-slate-900 border border-slate-700 rounded-xl px-3.5 py-2 flex-1 text-xs text-white placeholder:text-slate-500 focus:outline-none focus:border-rose-500"
                />
                <button
                  onClick={handleSendChatMessage}
                  className="px-4 py-2 bg-rose-600 hover:bg-rose-700 text-white font-bold text-xs rounded-xl transition shadow"
                >
                  Enviar
                </button>
              </div>
            </>
          ) : (
            <div className="flex-1 flex items-center justify-center text-slate-500 text-xs">
              Selecione um incidente na fila esquerda para iniciar o atendimento.
            </div>
          )}
        </section>

        {/* ------------------------------------------------------------------ */}
        {/* PAINEL DIREITO: MECANISMO DE RESOLUÇÃO E COMPENSAÇÕES (RN-106/141)  */}
        {/* ------------------------------------------------------------------ */}
        <aside className="col-span-4 bg-slate-950 flex flex-col overflow-y-auto p-5 space-y-5">
          <div className="border-b border-slate-800 pb-3">
            <h2 className="text-sm font-bold text-white uppercase tracking-wider">
              Resolução & Compensações (RN-106 / RN-141)
            </h2>
            <p className="text-xs text-slate-400 mt-0.5">
              Decisão formal auditada no Livro Razão e crédito na carteira do cliente.
            </p>
          </div>

          {selectedTicket && selectedTicket.estado === 'RESOLVIDO' ? (
            /* Ticket já Resolvido: Exibição Imutável (RN-142) */
            <div className="p-4 rounded-2xl bg-slate-900 border border-emerald-700/60 space-y-3">
              <div className="flex items-center space-x-2 text-emerald-400 font-bold text-xs uppercase">
                <span>✓</span>
                <span>Decisão Proferida e Congelada (RN-142)</span>
              </div>

              <div className="space-y-2 text-xs">
                <div>
                  <span className="text-slate-400">Decisão Formal:</span>{' '}
                  <span className="font-bold text-white">{selectedTicket.decisaoResolucao?.decisao}</span>
                </div>
                <div>
                  <span className="text-slate-400">Compensação Concedida:</span>{' '}
                  <span className="font-bold text-emerald-400 font-mono">
                    {selectedTicket.decisaoResolucao?.compensacaoValorKz.toLocaleString()} Kz
                  </span>
                </div>
                <div>
                  <span className="text-slate-400">Fundamentação:</span>
                  <p className="text-slate-200 mt-1 p-2.5 bg-slate-950 rounded-xl border border-slate-800 leading-relaxed">
                    {selectedTicket.decisaoResolucao?.motivoJustificacao}
                  </p>
                </div>
                <div className="text-[10px] text-slate-500 font-mono pt-1">
                  Decidido por: {selectedTicket.decisaoResolucao?.autorEmail} em {selectedTicket.decisaoResolucao?.resolvidoEm}
                </div>
              </div>
            </div>
          ) : (
            /* Formulário Ativo de Resolução */
            <div className="space-y-4">
              {/* 1. Seleção da Decisão Formal (RN-141) */}
              <div>
                <label className="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-1.5">
                  Decisão Formal da Disputa (RN-141) *
                </label>
                <div className="grid grid-cols-1 gap-2 text-xs">
                  {[
                    { id: 'Procedente_Cliente', label: 'Procedente Cliente (Reembolso / Crédito)', desc: 'Falha do parceiro ou estafeta comprovada' },
                    { id: 'Procedente_Parceiro', label: 'Procedente Parceiro (Loja Isenta)', desc: 'Cancelamento indevido ou má-fé do cliente' },
                    { id: 'Improcedente', label: 'Improcedente (Disputa Rejeitada)', desc: 'Sem evidências materiais de inconformidade' },
                  ].map((d) => (
                    <label
                      key={d.id}
                      className={`p-2.5 rounded-xl border cursor-pointer flex flex-col transition ${
                        decisao === d.id
                          ? 'bg-rose-950/30 border-rose-500 ring-1 ring-rose-500'
                          : 'bg-slate-900 border-slate-800 hover:border-slate-700'
                      }`}
                    >
                      <div className="flex items-center space-x-2">
                        <input
                          type="radio"
                          name="decisao"
                          value={d.id}
                          checked={decisao === d.id}
                          onChange={(e) => setDecisao(e.target.value as DisputeDecision)}
                          className="text-rose-600 focus:ring-rose-500"
                        />
                        <span className="font-bold text-white text-xs">{d.label}</span>
                      </div>
                      <span className="text-[10px] text-slate-400 pl-5 mt-0.5">{d.desc}</span>
                    </label>
                  ))}
                </div>
              </div>

              {/* 2. Campo Numérico de Compensação / Crédito (RN-071, RN-105) */}
              <div>
                <div className="flex items-center justify-between mb-1.5">
                  <label className="text-xs font-bold text-slate-300 uppercase tracking-wider">
                    Crédito de Compensação na Carteira (Kz)
                  </label>
                  <span className="text-[10px] text-slate-400">
                    Alçada Agente: <strong className="text-white">3.000 Kz</strong>
                  </span>
                </div>

                <div className="relative">
                  <input
                    type="number"
                    min={0}
                    step={100}
                    value={compensacaoValorKz}
                    onChange={(e) => setCompensacaoValorKz(Math.max(0, Number(e.target.value)))}
                    className={`w-full bg-slate-900 border rounded-xl px-3.5 py-2.5 font-mono text-sm font-bold text-emerald-400 focus:outline-none ${
                      isBloqueadoPorAlcada ? 'border-amber-500 ring-1 ring-amber-500' : 'border-slate-700'
                    }`}
                  />
                  <span className="absolute right-3.5 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-500">
                    Kz
                  </span>
                </div>
              </div>

              {/* 3. Bloqueio Lógico de Alçada e PIN de Supervisor (RN-106) */}
              {isValorExcedido && currentUserRole === 'AGENTE_BASE' && (
                <div className="p-3.5 rounded-xl bg-amber-950/40 border border-amber-600/80 space-y-2.5 text-xs">
                  <div className="flex items-start space-x-2 text-amber-300 font-bold">
                    <span className="text-base">⚠️</span>
                    <span>
                      RN-106: O valor ({compensacaoValorKz.toLocaleString()} Kz) excede o limite do Agente Base (3.000 Kz).
                    </span>
                  </div>
                  <p className="text-[11px] text-slate-300">
                    Para prosseguir com compensação superior a 3.000 Kz, introduza o PIN de autorização de um Supervisor
                    (PIN Demo: <strong>9988</strong>):
                  </p>

                  <div className="flex items-center space-x-2">
                    <input
                      type="password"
                      maxLength={6}
                      value={supervisorPin}
                      onChange={(e) => handleVerifySupervisorPin(e.target.value)}
                      placeholder="PIN do Supervisor..."
                      className="bg-slate-900 border border-amber-500 rounded-lg px-3 py-1.5 text-xs text-white font-mono w-40 text-center tracking-widest focus:outline-none"
                    />
                    {isSupervisorAuthorized ? (
                      <span className="text-emerald-400 font-bold text-xs flex items-center space-x-1">
                        <span>✓</span>
                        <span>Autorizado</span>
                      </span>
                    ) : (
                      <span className="text-amber-400 text-[10px]">Aguardando PIN...</span>
                    )}
                  </div>
                </div>
              )}

              {/* 4. Fundamentação Circunstanciada Obrigatória (RN-142) */}
              <div>
                <label className="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-1.5">
                  Fundamentação e Justificação da Decisão (RN-142) *
                </label>
                <textarea
                  rows={4}
                  value={motivoJustificacao}
                  onChange={(e) => setMotivoJustificacao(e.target.value)}
                  placeholder="Descreva a fundamentação técnica com base no histórico do OMS, logs de GPS e evidências..."
                  className="w-full bg-slate-900 border border-slate-700 text-xs rounded-xl p-3 text-slate-100 placeholder:text-slate-500 focus:outline-none focus:border-rose-500"
                />
              </div>

              {/* 5. Botão de Submissão com Desativação Lógica */}
              <div className="pt-2">
                <button
                  onClick={handleSubmitResolution}
                  disabled={isSubmittingResolution || isBloqueadoPorAlcada}
                  className={`w-full py-3 rounded-xl font-bold text-xs shadow-lg transition flex items-center justify-center space-x-2 ${
                    isBloqueadoPorAlcada
                      ? 'bg-slate-800 text-slate-500 cursor-not-allowed border border-slate-700'
                      : 'bg-rose-600 hover:bg-rose-700 text-white shadow-rose-950'
                  }`}
                >
                  {isSubmittingResolution ? (
                    <span>A registar resolução imutável...</span>
                  ) : (
                    <>
                      <span>Submeter Resolução da Disputa (RN-141)</span>
                      <span>✓</span>
                    </>
                  )}
                </button>

                {isBloqueadoPorAlcada && (
                  <p className="text-[10px] text-amber-400 text-center mt-2 font-semibold">
                    Botão desativado: requer PIN de autorização de um Supervisor (RN-106).
                  </p>
                )}
              </div>
            </div>
          )}
        </aside>
      </div>
    </div>
  );
};

export default SupportAgentConsole;


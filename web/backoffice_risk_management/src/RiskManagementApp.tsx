import React, { useState, useEffect } from 'react';
import {
  AvailableCourier,
  BlacklistEntry,
  BlacklistIdentifierType,
  CriticalActiveOrder,
  FraudAlert,
  FraudSeverity,
  FraudType,
} from './types';
import { RiskInterventionService } from './services/riskInterventionService';

export const RiskManagementApp: React.FC = () => {
  // Navegação entre módulos do ERP
  const [activeTab, setActiveTab] = useState<'HIGH_RISK_ACCOUNTS' | 'BLACKLIST' | 'MANUAL_DISPATCH'>(
    'HIGH_RISK_ACCOUNTS'
  );

  // Estados de dados
  const [fraudAlerts, setFraudAlerts] = useState<FraudAlert[]>([]);
  const [blacklist, setBlacklist] = useState<BlacklistEntry[]>([]);
  const [criticalOrders, setCriticalOrders] = useState<CriticalActiveOrder[]>([]);
  const [availableCouriers, setAvailableCouriers] = useState<AvailableCourier[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error' | 'info'; message: string } | null>(null);

  // Modal 1: Suspensão de Conta (RN-008 / RN-135)
  const [suspendingAlert, setSuspendingAlert] = useState<FraudAlert | null>(null);
  const [suspensionReason, setSuspensionReason] = useState<string>('');
  const [addSuspectToBlacklist, setAddSuspectToBlacklist] = useState<boolean>(true);
  const [isProcessingSuspension, setIsProcessingSuspension] = useState<boolean>(false);

  // Modal 2: Inserção Manual na Blacklist (RN-135)
  const [showAddBlacklistModal, setShowAddBlacklistModal] = useState<boolean>(false);
  const [newBlacklistType, setNewBlacklistType] = useState<BlacklistIdentifierType>('DEVICE_ID');
  const [newBlacklistValue, setNewBlacklistValue] = useState<string>('');
  const [newBlacklistReason, setNewBlacklistReason] = useState<string>('');
  const [newBlacklistFile, setNewBlacklistFile] = useState<File | null>(null);
  const [isAddingBlacklist, setIsAddingBlacklist] = useState<boolean>(false);

  // Modal 3: Reatribuição Manual Forçada de Pedido (Secção 5.2 / RN-088)
  const [reassigningOrder, setReassigningOrder] = useState<CriticalActiveOrder | null>(null);
  const [selectedCourierId, setSelectedCourierId] = useState<string>('');
  const [reassignmentAuditReason, setReassignmentAuditReason] = useState<string>('');
  const [isProcessingReassignment, setIsProcessingReassignment] = useState<boolean>(false);

  // Filtros de busca
  const [searchQuery, setSearchQuery] = useState<string>('');
  const [filterSeverity, setFilterSeverity] = useState<string>('TODAS');

  // Carregamento inicial de dados
  useEffect(() => {
    loadAllData();
  }, []);

  const loadAllData = async () => {
    setIsLoading(true);
    try {
      const [alerts, bl, orders] = await Promise.all([
        RiskInterventionService.getFraudAlerts(),
        RiskInterventionService.getBlacklist(),
        RiskInterventionService.getCriticalOrders(),
      ]);
      setFraudAlerts(alerts);
      setBlacklist(bl);
      setCriticalOrders(orders);
    } catch {
      setFeedback({ type: 'error', message: 'Erro ao carregar dados do ERP de Risco.' });
    } finally {
      setIsLoading(false);
    }
  };

  // Ação 1: Confirmar Suspensão de Conta (RN-008 / RN-135)
  const handleConfirmSuspension = async () => {
    if (!suspendingAlert) return;
    if (!suspensionReason.trim() || suspensionReason.length < 10) {
      setFeedback({ type: 'error', message: 'É obrigatório indicar uma justificação detalhada (mínimo 10 caracteres).' });
      return;
    }

    setIsProcessingSuspension(true);
    const res = await RiskInterventionService.suspendAccount({
      utilizadorId: suspendingAlert.utilizadorId,
      motivo: suspensionReason,
      operadorId: 'admin_helpdesk@delivery.ao',
      adicionarBlacklist: addSuspectToBlacklist,
      tipoIdentificador: suspendingAlert.tipoFraude === 'GPS_FALSO_VELOCIDADE_IMPOSSIVEL' ? 'ESTAFETA_ID' : 'DEVICE_ID',
      valorIdentificador: suspendingAlert.evidencias.deviceId || suspendingAlert.utilizadorId,
    });
    setIsProcessingSuspension(false);

    if (res.sucesso) {
      setFraudAlerts((prev) =>
        prev.map((a) => (a.id === suspendingAlert.id ? { ...a, estadoConta: 'SUSPENSO', resolvido: true } : a))
      );
      if (addSuspectToBlacklist) {
        setBlacklist((prev) => [
          {
            id: `blk-${Date.now()}`,
            tipoIdentificador: suspendingAlert.tipoFraude === 'GPS_FALSO_VELOCIDADE_IMPOSSIVEL' ? 'ESTAFETA_ID' : 'DEVICE_ID',
            valorIdentificador: suspendingAlert.evidencias.deviceId || suspendingAlert.utilizadorId,
            motivo: suspensionReason,
            scoreRisco: suspendingAlert.scoreRisco,
            bloqueadoPor: 'admin_helpdesk@delivery.ao',
            dataBloqueio: new Date().toISOString().replace('T', ' ').substring(0, 19),
            isAtivo: true,
          },
          ...prev,
        ]);
      }
      setFeedback({ type: 'success', message: res.mensagem });
      setSuspendingAlert(null);
      setSuspensionReason('');
    } else {
      setFeedback({ type: 'error', message: res.mensagem });
    }
  };

  // Ação 2: Confirmar Adição Manual na Blacklist (RN-135)
  const handleConfirmAddBlacklist = async () => {
    if (!newBlacklistValue.trim()) {
      setFeedback({ type: 'error', message: 'O valor do identificador a bloquear é obrigatório.' });
      return;
    }
    if (!newBlacklistReason.trim() || newBlacklistReason.length < 15) {
      setFeedback({ type: 'error', message: 'Justificação obrigatória com fundamentação do caso (mínimo 15 caracteres).' });
      return;
    }

    setIsAddingBlacklist(true);
    const fd = new FormData();
    fd.append('tipo_identificador', newBlacklistType);
    fd.append('valor_identificador', newBlacklistValue);
    fd.append('motivo', newBlacklistReason);
    if (newBlacklistFile) {
      fd.append('evidencia_doc', newBlacklistFile);
    }

    const res = await RiskInterventionService.addToBlacklist(fd);
    setIsAddingBlacklist(false);

    if (res.sucesso) {
      setBlacklist((prev) => [
        {
          id: `blk-${Date.now()}`,
          tipoIdentificador: newBlacklistType,
          valorIdentificador: newBlacklistValue,
          motivo: newBlacklistReason,
          scoreRisco: 100,
          evidenciaFicheiroNome: newBlacklistFile?.name,
          bloqueadoPor: 'operador_fraude@delivery.ao',
          dataBloqueio: new Date().toISOString().replace('T', ' ').substring(0, 19),
          isAtivo: true,
        },
        ...prev,
      ]);
      setFeedback({ type: 'success', message: res.mensagem });
      setShowAddBlacklistModal(false);
      setNewBlacklistValue('');
      setNewBlacklistReason('');
      setNewBlacklistFile(null);
    } else {
      setFeedback({ type: 'error', message: res.mensagem });
    }
  };

  // Ação 3: Abrir Modal de Reatribuição Forçada (RN-088)
  const handleOpenReassignment = async (order: CriticalActiveOrder) => {
    setReassigningOrder(order);
    setSelectedCourierId('');
    setReassignmentAuditReason('');
    const couriers = await RiskInterventionService.getAvailableCouriers(order.id);
    setAvailableCouriers(couriers);
    if (couriers.length > 0) {
      setSelectedCourierId(couriers[0].id);
    }
  };

  // Ação 4: Confirmar Reatribuição Forçada com Auditoria (Secção 5.2 / EventoPedido)
  const handleConfirmReassignment = async () => {
    if (!reassigningOrder) return;
    if (!selectedCourierId) {
      setFeedback({ type: 'error', message: 'Selecione um estafeta online na zona para alocação direta.' });
      return;
    }
    if (!reassignmentAuditReason.trim() || reassignmentAuditReason.length < 10) {
      setFeedback({
        type: 'error',
        message: 'Secção 5.2: O registo do motivo da intervenção no log imutável de auditoria é obrigatório (mínimo 10 caracteres).',
      });
      return;
    }

    setIsProcessingReassignment(true);
    const courierObj = availableCouriers.find((c) => c.id === selectedCourierId);

    const res = await RiskInterventionService.forceReassignCourier({
      pedidoId: reassigningOrder.id,
      novoEstafetaId: selectedCourierId,
      motivoAuditoria: reassignmentAuditReason,
      operadorId: 'controlador_trafego@delivery.ao',
    });
    setIsProcessingReassignment(false);

    if (res.sucesso) {
      setCriticalOrders((prev) =>
        prev.map((o) =>
          o.id === reassigningOrder.id
            ? {
                ...o,
                status: 'ESTAFETA_A_CAMINHO_RECOLHA',
                alarmeCritico: false,
                estafetaAtual: courierObj
                  ? {
                      id: courierObj.id,
                      nome: courierObj.nome,
                      telemovel: courierObj.telemovel,
                      distanciaAteLojaKm: courierObj.distanciaKm,
                    }
                  : undefined,
              }
            : o
        )
      );
      setFeedback({ type: 'success', message: res.mensagem });
      setReassigningOrder(null);
    } else {
      setFeedback({ type: 'error', message: res.mensagem });
    }
  };

  // Filtragem de Alertas
  const filteredAlerts = fraudAlerts.filter((a) => {
    const matchesSearch =
      a.utilizadorNome.toLowerCase().includes(searchQuery.toLowerCase()) ||
      a.utilizadorTelemovel.includes(searchQuery) ||
      a.descricao.toLowerCase().includes(searchQuery.toLowerCase()) ||
      a.id.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesSeverity = filterSeverity === 'TODAS' || a.severidade === filterSeverity;
    return matchesSearch && matchesSeverity;
  });

  return (
    <div className="min-h-screen bg-slate-900 text-slate-100 font-sans antialiased flex flex-col selection:bg-rose-600 selection:text-white">
      {/* 1. Header Corporativo de Alta Densidade de Informação */}
      <header className="bg-slate-950 border-b border-slate-800 sticky top-0 z-40 px-6 py-3.5 flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-center space-x-4">
          <div className="w-10 h-10 rounded-xl bg-gradient-to-tr from-rose-600 to-amber-600 flex items-center justify-center text-white font-black text-xl shadow-lg shadow-rose-950">
            🛡
          </div>
          <div>
            <div className="flex items-center space-x-2">
              <h1 className="text-base font-black tracking-tight text-white uppercase">Gestão de Risco & Intervenção</h1>
              <span className="px-2 py-0.5 rounded text-[10px] font-bold bg-rose-500/20 text-rose-300 border border-rose-500/30">
                Backoffice ERP
              </span>
            </div>
            <p className="text-xs text-slate-400">
              Antifraude (6.14), Disputas (6.15) e Controlo de Tráfego Logístico (5.2, RN-088)
            </p>
          </div>
        </div>

        {/* Módulos de Navegação Superior */}
        <div className="flex items-center space-x-1.5 bg-slate-900 p-1.5 rounded-xl border border-slate-800 text-xs">
          <button
            onClick={() => setActiveTab('HIGH_RISK_ACCOUNTS')}
            className={`px-3.5 py-2 rounded-lg font-bold transition flex items-center space-x-2 ${
              activeTab === 'HIGH_RISK_ACCOUNTS'
                ? 'bg-rose-600 text-white shadow-md shadow-rose-950'
                : 'text-slate-400 hover:text-white hover:bg-slate-800'
            }`}
          >
            <span>⚠️ Contas de Alto Risco</span>
            <span className="px-1.5 py-0.2 rounded-full bg-slate-950/60 text-[10px] font-mono">
              {fraudAlerts.filter((a) => !a.resolvido).length}
            </span>
          </button>

          <button
            onClick={() => setActiveTab('BLACKLIST')}
            className={`px-3.5 py-2 rounded-lg font-bold transition flex items-center space-x-2 ${
              activeTab === 'BLACKLIST'
                ? 'bg-rose-600 text-white shadow-md shadow-rose-950'
                : 'text-slate-400 hover:text-white hover:bg-slate-800'
            }`}
          >
            <span>🚫 Lista de Bloqueio</span>
            <span className="px-1.5 py-0.2 rounded-full bg-slate-950/60 text-[10px] font-mono">
              {blacklist.length}
            </span>
          </button>

          <button
            onClick={() => setActiveTab('MANUAL_DISPATCH')}
            className={`px-3.5 py-2 rounded-lg font-bold transition flex items-center space-x-2 ${
              activeTab === 'MANUAL_DISPATCH'
                ? 'bg-amber-600 text-white shadow-md shadow-amber-950'
                : 'text-slate-400 hover:text-white hover:bg-slate-800'
            }`}
          >
            <span>🚨 Intervenção Manual de Pedidos</span>
            <span className="px-1.5 py-0.2 rounded-full bg-slate-950/60 text-[10px] font-mono">
              {criticalOrders.filter((o) => o.alarmeCritico).length}
            </span>
          </button>
        </div>

        {/* Status do Operador */}
        <div className="flex items-center space-x-3 text-xs">
          <div className="text-right hidden sm:block">
            <span className="text-slate-200 font-bold block">Operador: Superadmin (Finanças/Risco)</span>
            <span className="text-emerald-400 flex items-center justify-end space-x-1 font-mono text-[10px]">
              <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse" />
              <span>Conexão WebSocket Ativa</span>
            </span>
          </div>
          <button
            onClick={loadAllData}
            title="Recarregar Dados"
            className="p-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 transition"
          >
            🔄
          </button>
        </div>
      </header>

      {/* Banner de Feedback Global */}
      {feedback && (
        <div className="px-6 py-2.5">
          <div
            className={`p-3 rounded-xl flex items-center justify-between text-xs font-semibold shadow-md ${
              feedback.type === 'success'
                ? 'bg-emerald-950/80 border border-emerald-700 text-emerald-200'
                : feedback.type === 'error'
                ? 'bg-rose-950/80 border border-rose-700 text-rose-200'
                : 'bg-blue-950/80 border border-blue-700 text-blue-200'
            }`}
          >
            <div className="flex items-center space-x-2">
              <span>{feedback.type === 'success' ? '✓' : '⚠'}</span>
              <span>{feedback.message}</span>
            </div>
            <button onClick={() => setFeedback(null)} className="underline hover:opacity-80">
              Dispensar
            </button>
          </div>
        </div>
      )}

      {/* Conteúdo Principal do Dashboard */}
      <main className="p-6 flex-1 flex flex-col space-y-6">
        {/* ==================================================================== */}
        {/* MÓDULO 1: PAINEL DE CONTAS DE ALTO RISCO (RN-130, RN-131, RN-133)   */}
        {/* ==================================================================== */}
        {activeTab === 'HIGH_RISK_ACCOUNTS' && (
          <div className="space-y-4">
            {/* Barra de Filtros e Busca Rápida */}
            <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex flex-wrap items-center justify-between gap-4">
              <div className="flex items-center space-x-3 flex-1 min-w-[280px]">
                <span className="text-slate-500">🔍</span>
                <input
                  type="text"
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  placeholder="Pesquisar por Utilizador, Telemóvel, ID de Alerta ou Hardware UUID..."
                  className="bg-slate-900 border border-slate-700 text-xs rounded-xl px-3.5 py-2 w-full focus:outline-none focus:border-rose-500 text-slate-100 placeholder:text-slate-500"
                />
              </div>

              <div className="flex items-center space-x-3 text-xs">
                <span className="text-slate-400 font-semibold">Filtrar Severidade:</span>
                <select
                  value={filterSeverity}
                  onChange={(e) => setFilterSeverity(e.target.value)}
                  className="bg-slate-900 border border-slate-700 rounded-xl px-3 py-2 text-slate-200 font-bold focus:outline-none"
                >
                  <option value="TODAS">Todas as Severidades</option>
                  <option value="CRITICA">Crítica (Score &ge; 80)</option>
                  <option value="ALTA">Alta (Score 60-79)</option>
                  <option value="MEDIA">Média (Score 40-59)</option>
                </select>
              </div>
            </div>

            {/* Tabela de Monitorização em Tempo Real */}
            <div className="bg-slate-950 rounded-2xl border border-slate-800 overflow-hidden shadow-xl">
              <div className="px-6 py-4 border-b border-slate-800 flex items-center justify-between">
                <div>
                  <h2 className="text-sm font-bold text-white uppercase tracking-wider">
                    Alertas de Fraude em Tempo Real (RN-130 a RN-134)
                  </h2>
                  <p className="text-xs text-slate-400">
                    Deteção probabilística contínua de multicontas no mesmo hardware e estafetas com telemetria anómala.
                  </p>
                </div>
                <span className="text-xs font-mono font-bold bg-slate-900 px-3 py-1 rounded-lg border border-slate-700 text-slate-300">
                  Total Alertas: {filteredAlerts.length}
                </span>
              </div>

              <div className="overflow-x-auto">
                <table className="w-full text-left text-xs border-collapse">
                  <thead>
                    <tr className="bg-slate-900/80 text-slate-400 uppercase tracking-wider border-b border-slate-800 font-bold">
                      <th className="py-3 px-4">Severidade & Risco</th>
                      <th className="py-3 px-4">Utilizador / Infrator</th>
                      <th className="py-3 px-4">Tipo de Fraude (Regra)</th>
                      <th className="py-3 px-4">Evidências Forenses (PCI DSS / Telemetria)</th>
                      <th className="py-3 px-4">Timestamp</th>
                      <th className="py-3 px-4 text-right">Ação de Risco (RN-008)</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-800/60">
                    {filteredAlerts.map((alert) => {
                      const isCritical = alert.severidade === 'CRITICA';
                      const isSuspended = alert.estadoConta === 'SUSPENSO';

                      return (
                        <tr
                          key={alert.id}
                          className={`transition hover:bg-slate-900/50 ${
                            isCritical && !isSuspended ? 'bg-rose-950/20' : ''
                          }`}
                        >
                          {/* Coluna 1: Severidade e Score */}
                          <td className="py-4 px-4 whitespace-nowrap">
                            <div className="flex items-center space-x-2">
                              <span
                                className={`px-2 py-0.5 rounded font-black text-[10px] tracking-wider ${
                                  alert.severidade === 'CRITICA'
                                    ? 'bg-rose-600 text-white animate-pulse'
                                    : alert.severidade === 'ALTA'
                                    ? 'bg-amber-600 text-white'
                                    : 'bg-blue-600 text-white'
                                }`}
                              >
                                {alert.severidade}
                              </span>
                              <span className="font-mono font-bold text-slate-200">
                                {alert.scoreRisco}/100
                              </span>
                            </div>
                          </td>

                          {/* Coluna 2: Utilizador */}
                          <td className="py-4 px-4 whitespace-nowrap">
                            <div>
                              <div className="font-bold text-white flex items-center space-x-1.5">
                                <span>{alert.utilizadorNome}</span>
                                <span className="text-[10px] px-1.5 py-0.2 rounded bg-slate-800 text-slate-300">
                                  {alert.utilizadorTipo}
                                </span>
                              </div>
                              <span className="font-mono text-slate-400 text-[11px] block">
                                {alert.utilizadorTelemovel}
                              </span>
                              {isSuspended && (
                                <span className="inline-block mt-1 text-[10px] font-bold text-rose-400 bg-rose-950/60 border border-rose-800/80 px-1.5 py-0.5 rounded">
                                  CONTA SUSPENSA (RN-008)
                                </span>
                              )}
                            </div>
                          </td>

                          {/* Coluna 3: Tipo de Fraude */}
                          <td className="py-4 px-4">
                            <div className="space-y-1">
                              <span className="font-bold text-rose-300 block">
                                {alert.tipoFraude === 'DISPOSITIVO_CARTAO_MULTICONTAS'
                                  ? 'RN-131: Multicontas no Mesmo Dispositivo'
                                  : alert.tipoFraude === 'GPS_FALSO_VELOCIDADE_IMPOSSIVEL'
                                  ? 'RN-133: Mock GPS / Velocidade Impossível'
                                  : alert.tipoFraude === 'ABUSO_PROMOCOES_MORADA'
                                  ? 'RN-132: Abuso de Cupões na Mesma Morada'
                                  : alert.tipoFraude}
                              </span>
                              <p className="text-slate-400 text-[11px] leading-relaxed max-w-sm">
                                {alert.descricao}
                              </p>
                            </div>
                          </td>

                          {/* Coluna 4: Evidências Forenses Estruturadas */}
                          <td className="py-4 px-4 font-mono text-[11px]">
                            <div className="space-y-0.5 text-slate-300">
                              {alert.evidencias.deviceId && (
                                <div>
                                  <span className="text-slate-500">Hardware UUID:</span>{' '}
                                  <span className="text-amber-400">{alert.evidencias.deviceId}</span>
                                </div>
                              )}
                              {alert.evidencias.mockGpsDetected && (
                                <div className="text-rose-400 font-bold">
                                  <span>🚨 Mock Location Ativo no SO</span>
                                </div>
                              )}
                              {alert.evidencias.velocidadeCalculadaKmh && (
                                <div>
                                  <span className="text-slate-500">Velocidade:</span>{' '}
                                  <span className="text-rose-400 font-bold">
                                    {alert.evidencias.velocidadeCalculadaKmh} km/h (Limite: 120 km/h)
                                  </span>
                                </div>
                              )}
                              {alert.evidencias.contasVinculadas && (
                                <div>
                                  <span className="text-slate-500">Contas:</span>{' '}
                                  <span>{alert.evidencias.contasVinculadas.length} contas partilhadas</span>
                                </div>
                              )}
                              {alert.evidencias.ipOrigem && (
                                <div>
                                  <span className="text-slate-500">IP:</span> <span>{alert.evidencias.ipOrigem}</span>
                                </div>
                              )}
                            </div>
                          </td>

                          {/* Coluna 5: Timestamp */}
                          <td className="py-4 px-4 whitespace-nowrap text-slate-400 font-mono text-[11px]">
                            {alert.dataAlerta}
                          </td>

                          {/* Coluna 6: Botão de Ação "Suspender Conta" */}
                          <td className="py-4 px-4 text-right whitespace-nowrap">
                            {isSuspended ? (
                              <button
                                disabled
                                className="px-3 py-1.5 rounded-lg bg-slate-800 text-slate-500 font-bold text-xs cursor-not-allowed border border-slate-700"
                              >
                                Já Suspenso
                              </button>
                            ) : (
                              <button
                                onClick={() => {
                                  setSuspendingAlert(alert);
                                  setSuspensionReason(
                                    `Suspensão preventiva por deteção automática de fraude: ${alert.descricao}`
                                  );
                                }}
                                className="px-3.5 py-1.5 rounded-lg bg-rose-600 hover:bg-rose-700 text-white font-bold text-xs shadow-md shadow-rose-950 transition flex items-center space-x-1.5 ml-auto"
                              >
                                <span>🔒</span>
                                <span>Suspender Conta</span>
                              </button>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        )}

        {/* ==================================================================== */}
        {/* MÓDULO 2: GESTOR DE LISTA DE BLOQUEIO (BLACKLIST - RN-135)          */}
        {/* ==================================================================== */}
        {activeTab === 'BLACKLIST' && (
          <div className="space-y-4">
            <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800 flex flex-wrap items-center justify-between gap-4">
              <div>
                <h2 className="text-base font-bold text-white uppercase tracking-wider">
                  Lista de Bloqueio Imutável (Blacklist - RN-135)
                </h2>
                <p className="text-xs text-slate-400">
                  Hardware UUIDs, telemóveis, emails e fingerprints SHA-256 banidos preventivamente contra fraudes reiteradas.
                </p>
              </div>

              <button
                onClick={() => setShowAddBlacklistModal(true)}
                className="px-4 py-2 bg-rose-600 hover:bg-rose-700 text-white font-bold text-xs rounded-xl shadow-lg shadow-rose-950 transition flex items-center space-x-2"
              >
                <span>+</span>
                <span>Inserir Identificador na Blacklist</span>
              </button>
            </div>

            {/* Tabela de Blacklist */}
            <div className="bg-slate-950 rounded-2xl border border-slate-800 overflow-hidden shadow-xl">
              <div className="overflow-x-auto">
                <table className="w-full text-left text-xs border-collapse">
                  <thead>
                    <tr className="bg-slate-900/80 text-slate-400 uppercase tracking-wider border-b border-slate-800 font-bold">
                      <th className="py-3 px-4">Tipo Identificador</th>
                      <th className="py-3 px-4">Valor Bloqueado</th>
                      <th className="py-3 px-4">Motivo Circunstanciado</th>
                      <th className="py-3 px-4">Evidência / Ficheiro</th>
                      <th className="py-3 px-4">Autor do Bloqueio</th>
                      <th className="py-3 px-4">Data Imutável</th>
                      <th className="py-3 px-4 text-center">Estado</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-800/60 font-mono">
                    {blacklist.map((entry) => (
                      <tr key={entry.id} className="hover:bg-slate-900/50">
                        <td className="py-3.5 px-4 whitespace-nowrap">
                          <span className="px-2 py-0.5 rounded bg-slate-800 text-amber-300 font-bold text-[10px]">
                            {entry.tipoIdentificador}
                          </span>
                        </td>
                        <td className="py-3.5 px-4 font-bold text-white break-all">
                          {entry.valorIdentificador}
                        </td>
                        <td className="py-3.5 px-4 font-sans text-slate-300 max-w-sm">
                          {entry.motivo}
                        </td>
                        <td className="py-3.5 px-4 font-sans text-xs">
                          {entry.evidenciaFicheiroNome ? (
                            <span className="text-emerald-400 flex items-center space-x-1 underline cursor-pointer">
                              <span>📎</span>
                              <span>{entry.evidenciaFicheiroNome}</span>
                            </span>
                          ) : (
                            <span className="text-slate-500 italic">Sem ficheiro anexado</span>
                          )}
                        </td>
                        <td className="py-3.5 px-4 text-slate-400 text-[11px]">
                          {entry.bloqueadoPor}
                        </td>
                        <td className="py-3.5 px-4 text-slate-400 text-[11px] whitespace-nowrap">
                          {entry.dataBloqueio}
                        </td>
                        <td className="py-3.5 px-4 text-center whitespace-nowrap">
                          <span className="px-2 py-0.5 rounded bg-rose-500/20 text-rose-300 border border-rose-500/30 font-bold text-[10px]">
                            ATIVO (IMUTÁVEL)
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        )}

        {/* ==================================================================== */}
        {/* MÓDULO 3: CONSOLA DE INTERVENÇÃO MANUAL DE PEDIDOS (5.2 & RN-088)    */}
        {/* ==================================================================== */}
        {activeTab === 'MANUAL_DISPATCH' && (
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 flex-1">
            {/* Lista Lateral de Pedidos Críticos / Sem Estafeta */}
            <div className="lg:col-span-5 space-y-4">
              <div className="bg-slate-950 p-4 rounded-2xl border border-slate-800">
                <div className="flex items-center justify-between">
                  <h2 className="text-sm font-bold text-white uppercase tracking-wider">
                    Fila de Atrasos Críticos (RN-088)
                  </h2>
                  <span className="text-xs bg-rose-600 text-white font-bold px-2 py-0.5 rounded-full">
                    {criticalOrders.filter((o) => o.alarmeCritico).length} Críticos
                  </span>
                </div>
                <p className="text-xs text-slate-400 mt-1">
                  Pedidos sem atribuição ou em risco iminente de quebra de SLA da janela de entrega.
                </p>
              </div>

              <div className="space-y-3">
                {criticalOrders.map((order) => {
                  const isAlarmActive = order.alarmeCritico;

                  return (
                    <div
                      key={order.id}
                      className={`p-4 rounded-2xl border transition ${
                        isAlarmActive
                          ? 'bg-slate-950 border-rose-500/60 shadow-lg shadow-rose-950/20'
                          : 'bg-slate-950/60 border-slate-800'
                      }`}
                    >
                      <div className="flex items-start justify-between">
                        <div>
                          <div className="flex items-center space-x-2">
                            <span className="text-sm font-black text-white font-mono">{order.codigoDisplay}</span>
                            <span
                              className={`text-[10px] font-bold px-2 py-0.5 rounded ${
                                isAlarmActive
                                  ? 'bg-rose-500 text-white animate-pulse'
                                  : 'bg-slate-800 text-slate-300'
                              }`}
                            >
                              {order.status}
                            </span>
                          </div>
                          <p className="text-xs font-bold text-slate-200 mt-1">{order.lojaNome}</p>
                          <p className="text-xs text-slate-400 mt-0.5">Destino: {order.clienteNome} ({order.clienteMorada})</p>
                        </div>

                        <div className="text-right">
                          <span className="text-xs font-mono font-bold text-rose-400">
                            {order.tempoDecorridoMinutos} min decorridos
                          </span>
                          <span className="text-[10px] text-slate-500 block">ETA: {order.etaEstimadaMinutos} min</span>
                        </div>
                      </div>

                      {/* Motivo do Alarme Operacional */}
                      {isAlarmActive && (
                        <div className="mt-3 p-2.5 rounded-xl bg-rose-950/40 border border-rose-800/60 text-xs text-rose-300 flex items-start space-x-2">
                          <span>🚨</span>
                          <span className="font-semibold">{order.motivoAlarme}</span>
                        </div>
                      )}

                      {/* Botão de Reatribuição Manual Forçada */}
                      <div className="mt-4 pt-3 border-t border-slate-800 flex justify-end">
                        <button
                          onClick={() => handleOpenReassignment(order)}
                          className="px-4 py-2 bg-amber-600 hover:bg-amber-700 text-white text-xs font-bold rounded-xl shadow-md transition flex items-center space-x-1.5"
                        >
                          <span>⚡</span>
                          <span>Reatribuição Manual Forçada</span>
                        </button>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>

            {/* Painel Tático Visual: Mapa da Cidade e Tráfego da Frota */}
            <div className="lg:col-span-7 bg-slate-950 rounded-2xl border border-slate-800 p-5 flex flex-col justify-between">
              <div>
                <div className="flex items-center justify-between pb-3 border-b border-slate-800">
                  <div className="flex items-center space-x-2">
                    <span className="text-xl">🗺️</span>
                    <div>
                      <h3 className="text-sm font-bold text-white uppercase tracking-wider">
                        Visão Espacial de Tráfego e Frota (PostGIS Luanda)
                      </h3>
                      <p className="text-xs text-slate-400">
                        Monitorização de Nós Logísticos (Lojas, Clientes e Estafetas em rota).
                      </p>
                    </div>
                  </div>
                  <span className="text-[10px] font-mono bg-emerald-950 text-emerald-300 border border-emerald-800 px-2 py-0.5 rounded">
                    Radar Ativo SRID 4326
                  </span>
                </div>

                {/* Renderização Tática em Canvas / SVG Simulado de Mapa Urbano */}
                <div className="mt-4 h-96 w-full rounded-xl bg-slate-900 border border-slate-800 relative overflow-hidden flex items-center justify-center">
                  {/* Grid de Coordenadas de Fundo */}
                  <div className="absolute inset-0 bg-[linear-gradient(to_right,#1e293b_1px,transparent_1px),linear-gradient(to_bottom,#1e293b_1px,transparent_1px)] bg-[size:32px_32px] opacity-40" />

                  {/* Representação de Vias Expressas de Luanda */}
                  <svg className="absolute inset-0 w-full h-full stroke-slate-700/60 stroke-2 fill-none">
                    <path d="M 50 150 Q 200 80 400 120 T 700 200" />
                    <path d="M 120 300 Q 350 250 550 350" />
                    <path d="M 300 50 L 320 380" strokeDasharray="4 4" />
                  </svg>

                  {/* Nós Logísticos: Lojas com Pedido Crítico */}
                  <div className="absolute top-28 left-40 flex flex-col items-center group cursor-pointer">
                    <div className="w-8 h-8 rounded-full bg-rose-600 text-white flex items-center justify-center font-bold text-xs ring-4 ring-rose-950 animate-bounce shadow-lg">
                      🍕
                    </div>
                    <span className="mt-1 text-[10px] font-bold bg-slate-950/80 px-1.5 py-0.5 rounded text-rose-300 border border-rose-800">
                      Napoli Talatona (#9049)
                    </span>
                  </div>

                  <div className="absolute top-52 left-80 flex flex-col items-center group cursor-pointer">
                    <div className="w-8 h-8 rounded-full bg-amber-600 text-white flex items-center justify-center font-bold text-xs ring-4 ring-amber-950 shadow-lg">
                      🍔
                    </div>
                    <span className="mt-1 text-[10px] font-bold bg-slate-950/80 px-1.5 py-0.5 rounded text-amber-300 border border-amber-800">
                      Burger Baixa (#9052)
                    </span>
                  </div>

                  {/* Nós Logísticos: Estafetas Online Próximos */}
                  <div className="absolute top-36 left-60 flex flex-col items-center group cursor-pointer">
                    <div className="w-7 h-7 rounded-full bg-emerald-600 text-white flex items-center justify-center text-xs ring-2 ring-emerald-400 shadow-md">
                      🏍️
                    </div>
                    <span className="mt-1 text-[9px] font-mono bg-slate-950/80 px-1 rounded text-emerald-400">
                      Mateus (1.2 km)
                    </span>
                  </div>

                  <div className="absolute top-44 left-96 flex flex-col items-center group cursor-pointer">
                    <div className="w-7 h-7 rounded-full bg-emerald-600 text-white flex items-center justify-center text-xs ring-2 ring-emerald-400 shadow-md">
                      🏍️
                    </div>
                    <span className="mt-1 text-[9px] font-mono bg-slate-950/80 px-1 rounded text-emerald-400">
                      Domingos (2.1 km)
                    </span>
                  </div>

                  {/* Legenda do Mapa */}
                  <div className="absolute bottom-3 left-3 bg-slate-950/90 border border-slate-800 p-2.5 rounded-xl text-[10px] space-y-1">
                    <div className="flex items-center space-x-2">
                      <span className="w-2.5 h-2.5 rounded-full bg-rose-500" />
                      <span className="text-slate-300">Loja com Alarme Crítico de Espera</span>
                    </div>
                    <div className="flex items-center space-x-2">
                      <span className="w-2.5 h-2.5 rounded-full bg-emerald-500" />
                      <span className="text-slate-300">Estafeta Online em Raio Operacional</span>
                    </div>
                  </div>
                </div>
              </div>

              {/* Informação Operacional da Frota */}
              <div className="mt-4 pt-4 border-t border-slate-800 grid grid-cols-3 gap-3 text-center text-xs">
                <div className="bg-slate-900/60 p-2.5 rounded-xl border border-slate-800">
                  <span className="text-slate-400 block text-[10px] uppercase font-bold">Frota Conectada</span>
                  <span className="text-sm font-black text-emerald-400 font-mono">48 Estafetas</span>
                </div>
                <div className="bg-slate-900/60 p-2.5 rounded-xl border border-slate-800">
                  <span className="text-slate-400 block text-[10px] uppercase font-bold">Em Rota Ativa</span>
                  <span className="text-sm font-black text-amber-400 font-mono">35 Entregas</span>
                </div>
                <div className="bg-slate-900/60 p-2.5 rounded-xl border border-slate-800">
                  <span className="text-slate-400 block text-[10px] uppercase font-bold">Disponíveis P/ Despacho</span>
                  <span className="text-sm font-black text-blue-400 font-mono">13 Livres</span>
                </div>
              </div>
            </div>
          </div>
        )}
      </main>

      {/* ==================================================================== */}
      {/* MODAL 1: SUSPENSÃO DE CONTA (RN-008 / RN-135)                         */}
      {/* ==================================================================== */}
      {suspendingAlert && (
        <div className="fixed inset-0 z-50 bg-black/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-950 border border-slate-800 rounded-3xl max-w-lg w-full p-6 space-y-5 shadow-2xl">
            <div className="flex items-center space-x-3 text-rose-500">
              <span className="text-2xl">🔒</span>
              <div>
                <h3 className="text-base font-bold text-white">Confirmar Suspensão Imediata de Conta</h3>
                <p className="text-xs text-slate-400">Regras RN-008 (Controlo de Perfil) e RN-135 (Mitigação de Risco)</p>
              </div>
            </div>

            <div className="p-3.5 rounded-xl bg-rose-950/30 border border-rose-900 text-xs space-y-1.5 text-slate-300">
              <p>
                <strong className="text-white">Alvo:</strong> {suspendingAlert.utilizadorNome} (
                {suspendingAlert.utilizadorTelemovel})
              </p>
              <p>
                <strong className="text-white">Tipo de Fraude:</strong> {suspendingAlert.tipoFraude}
              </p>
              <p>
                <strong className="text-white">Score de Risco:</strong> {suspendingAlert.scoreRisco}/100
              </p>
            </div>

            <div>
              <label className="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-1">
                Justificação Circunstanciada para o Log de Auditoria *
              </label>
              <textarea
                rows={3}
                value={suspensionReason}
                onChange={(e) => setSuspensionReason(e.target.value)}
                placeholder="Indique os motivos fundamentados para suspensão..."
                className="w-full bg-slate-900 border border-slate-700 text-xs rounded-xl p-3 focus:outline-none focus:border-rose-500 text-slate-100"
              />
            </div>

            <label className="flex items-center space-x-2.5 text-xs text-slate-300 cursor-pointer">
              <input
                type="checkbox"
                checked={addSuspectToBlacklist}
                onChange={(e) => setAddSuspectToBlacklist(e.target.checked)}
                className="rounded border-slate-700 bg-slate-900 text-rose-600 focus:ring-rose-500"
              />
              <span>Inscrição automática na Lista de Bloqueio Imutável (RN-135)</span>
            </label>

            <div className="flex justify-end space-x-3 pt-3 border-t border-slate-800">
              <button
                onClick={() => setSuspendingAlert(null)}
                className="px-4 py-2 border border-slate-700 text-slate-300 hover:bg-slate-900 rounded-xl text-xs font-bold"
              >
                Cancelar
              </button>
              <button
                onClick={handleConfirmSuspension}
                disabled={isProcessingSuspension}
                className="px-5 py-2 bg-rose-600 hover:bg-rose-700 text-white rounded-xl text-xs font-bold shadow-lg shadow-rose-950 flex items-center space-x-1.5"
              >
                {isProcessingSuspension ? <span>A processar...</span> : <span>Confirmar Bloqueio de Perfil</span>}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ==================================================================== */}
      {/* MODAL 2: INSERÇÃO MANUAL NA BLACKLIST (RN-135)                       */}
      {/* ==================================================================== */}
      {showAddBlacklistModal && (
        <div className="fixed inset-0 z-50 bg-black/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-950 border border-slate-800 rounded-3xl max-w-lg w-full p-6 space-y-5 shadow-2xl">
            <div className="flex items-center justify-between border-b border-slate-800 pb-3">
              <div className="flex items-center space-x-2">
                <span className="text-xl">🚫</span>
                <h3 className="text-base font-bold text-white">Inserir Entrada na Blacklist Imutável</h3>
              </div>
              <button onClick={() => setShowAddBlacklistModal(false)} className="text-slate-400 hover:text-white">
                ✕
              </button>
            </div>

            <div className="space-y-4 text-xs">
              <div>
                <label className="block font-bold text-slate-300 uppercase mb-1">Tipo de Identificador *</label>
                <select
                  value={newBlacklistType}
                  onChange={(e) => setNewBlacklistType(e.target.value as BlacklistIdentifierType)}
                  className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-2 text-slate-200 font-bold focus:outline-none"
                >
                  <option value="DEVICE_ID">Hardware UUID do Dispositivo (Device ID)</option>
                  <option value="CARD_FINGERPRINT">Fingerprint SHA-256 do Cartão Bancário</option>
                  <option value="TELEMOVEL">Número de Telemóvel E.164</option>
                  <option value="EMAIL">Endereço de Email</option>
                  <option value="ESTAFETA_ID">ID do Estafeta Infrator</option>
                  <option value="IP_ADDRESS">Endereço IP</option>
                </select>
              </div>

              <div>
                <label className="block font-bold text-slate-300 uppercase mb-1">Valor do Identificador a Bloquear *</label>
                <input
                  type="text"
                  value={newBlacklistValue}
                  onChange={(e) => setNewBlacklistValue(e.target.value)}
                  placeholder="Ex: hw_uuid_9f8a1234... ou +244923000000"
                  className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-2 font-mono text-slate-100 focus:outline-none focus:border-rose-500"
                />
              </div>

              <div>
                <label className="block font-bold text-slate-300 uppercase mb-1">Justificação Fundamentada *</label>
                <textarea
                  rows={3}
                  value={newBlacklistReason}
                  onChange={(e) => setNewBlacklistReason(e.target.value)}
                  placeholder="Descreva a evidência de fraude apurada para efeito de auditoria..."
                  className="w-full bg-slate-900 border border-slate-700 rounded-xl p-3 text-slate-100 focus:outline-none focus:border-rose-500"
                />
              </div>

              <div>
                <label className="block font-bold text-slate-300 uppercase mb-1">Ficheiro de Evidência (PDF/CSV/PNG)</label>
                <input
                  type="file"
                  onChange={(e) => setNewBlacklistFile(e.target.files?.[0] || null)}
                  className="w-full text-slate-400 file:mr-3 file:py-1.5 file:px-3 file:rounded-lg file:border-0 file:bg-slate-800 file:text-xs file:font-bold file:text-slate-200 hover:file:bg-slate-700"
                />
              </div>
            </div>

            <div className="flex justify-end space-x-3 pt-3 border-t border-slate-800">
              <button
                onClick={() => setShowAddBlacklistModal(false)}
                className="px-4 py-2 border border-slate-700 text-slate-300 hover:bg-slate-900 rounded-xl text-xs font-bold"
              >
                Cancelar
              </button>
              <button
                onClick={handleConfirmAddBlacklist}
                disabled={isAddingBlacklist}
                className="px-5 py-2 bg-rose-600 hover:bg-rose-700 text-white rounded-xl text-xs font-bold shadow-lg shadow-rose-950"
              >
                {isAddingBlacklist ? 'A registar...' : 'Gravar Entrada Imutável (RN-135)'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ==================================================================== */}
      {/* MODAL 3: REATRIBUIÇÃO MANUAL FORÇADA (Secção 5.2 / RN-088)          */}
      {/* ==================================================================== */}
      {reassigningOrder && (
        <div className="fixed inset-0 z-50 bg-black/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-950 border border-slate-800 rounded-3xl max-w-xl w-full p-6 space-y-5 shadow-2xl">
            <div className="flex items-center justify-between border-b border-slate-800 pb-3">
              <div className="flex items-center space-x-2 text-amber-500">
                <span className="text-2xl">⚡</span>
                <div>
                  <h3 className="text-base font-bold text-white">Reatribuição Manual Forçada de Estafeta</h3>
                  <p className="text-xs text-slate-400">Secção 5.2 (OMS) e Regra RN-088 (Alocação Excecional)</p>
                </div>
              </div>
              <button onClick={() => setReassigningOrder(null)} className="text-slate-400 hover:text-white">
                ✕
              </button>
            </div>

            {/* Sumário do Pedido Alvo */}
            <div className="p-3.5 rounded-xl bg-slate-900 border border-slate-800 text-xs space-y-1">
              <p>
                <strong className="text-white">Pedido:</strong> {reassigningOrder.codigoDisplay} •{' '}
                <span className="text-amber-400 font-bold">{reassigningOrder.tempoDecorridoMinutos} min decorridos</span>
              </p>
              <p>
                <strong className="text-white">Loja de Origem:</strong> {reassigningOrder.lojaNome}
              </p>
              <p>
                <strong className="text-white">Destino:</strong> {reassigningOrder.clienteNome} (
                {reassigningOrder.clienteMorada})
              </p>
            </div>

            {/* Lista de Estafetas Online no Raio Operacional */}
            <div>
              <label className="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-2">
                Selecione o Estafeta Online na Zona Logística:
              </label>

              <div className="space-y-2 max-h-48 overflow-y-auto pr-1">
                {availableCouriers.map((courier) => {
                  const isSelected = selectedCourierId === courier.id;

                  return (
                    <div
                      key={courier.id}
                      onClick={() => setSelectedCourierId(courier.id)}
                      className={`p-3 rounded-xl border cursor-pointer transition flex items-center justify-between text-xs ${
                        isSelected
                          ? 'bg-amber-950/30 border-amber-500 ring-1 ring-amber-500'
                          : 'bg-slate-900 border-slate-800 hover:border-slate-700'
                      }`}
                    >
                      <div className="flex items-center space-x-3">
                        <input
                          type="radio"
                          name="selectedCourier"
                          checked={isSelected}
                          onChange={() => setSelectedCourierId(courier.id)}
                          className="text-amber-600 focus:ring-amber-500"
                        />
                        <div>
                          <div className="font-bold text-white flex items-center space-x-1.5">
                            <span>{courier.nome}</span>
                            <span className="text-[10px] text-slate-400">({courier.veiculo})</span>
                          </div>
                          <span className="text-[11px] text-slate-400 font-mono">
                            Distância: {courier.distanciaKm} km • Bateria: {courier.bateriaNivelPct}% • Score:{' '}
                            {courier.classificacaoEstrelas}★
                          </span>
                        </div>
                      </div>

                      <span className="px-2 py-0.5 rounded bg-emerald-950 text-emerald-300 font-bold text-[10px]">
                        LIVRE (0 Pedidos)
                      </span>
                    </div>
                  );
                })}
              </div>
            </div>

            {/* Campo Obrigatório para Registo em Auditoria Imutável */}
            <div>
              <label className="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-1">
                Motivo da Intervenção para o Log de Auditoria (Secção 5.2 - EventoPedido) *
              </label>
              <textarea
                rows={2}
                value={reassignmentAuditReason}
                onChange={(e) => setReassignmentAuditReason(e.target.value)}
                placeholder="Ex: Reatribuição manual motivada por rejeições consecutivas e proteção de SLA do cliente..."
                className="w-full bg-slate-900 border border-slate-700 text-xs rounded-xl p-2.5 focus:outline-none focus:border-amber-500 text-slate-100"
              />
            </div>

            <div className="flex justify-end space-x-3 pt-3 border-t border-slate-800">
              <button
                onClick={() => setReassigningOrder(null)}
                className="px-4 py-2 border border-slate-700 text-slate-300 hover:bg-slate-900 rounded-xl text-xs font-bold"
              >
                Cancelar
              </button>
              <button
                onClick={handleConfirmReassignment}
                disabled={isProcessingReassignment}
                className="px-5 py-2 bg-amber-600 hover:bg-amber-700 text-white rounded-xl text-xs font-bold shadow-lg shadow-amber-950 flex items-center space-x-1.5"
              >
                {isProcessingReassignment ? <span>A despachar...</span> : <span>Confirmar Despacho Forçado</span>}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default RiskManagementApp;

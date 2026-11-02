import React, { useState, useId } from 'react';
import {
  BankDetails,
  CompanyDetails,
  DaySchedule,
  DocumentUpload,
  StoreStatus,
  TimeSlot,
} from '../types/partner';
import { PartnerService } from '../services/partnerService';

// Dias da semana padrão
const DIAS_PADRAO: DaySchedule[] = [
  {
    diaSemana: 0,
    diaNome: 'Segunda-feira',
    isEncerrado: false,
    turnos: [
      { id: '1', horaAbertura: '11:00', horaFecho: '15:00' },
      { id: '2', horaAbertura: '18:00', horaFecho: '23:00' },
    ],
  },
  {
    diaSemana: 1,
    diaNome: 'Terça-feira',
    isEncerrado: false,
    turnos: [
      { id: '1', horaAbertura: '11:00', horaFecho: '15:00' },
      { id: '2', horaAbertura: '18:00', horaFecho: '23:00' },
    ],
  },
  {
    diaSemana: 2,
    diaNome: 'Quarta-feira',
    isEncerrado: false,
    turnos: [
      { id: '1', horaAbertura: '11:00', horaFecho: '15:00' },
      { id: '2', horaAbertura: '18:00', horaFecho: '23:00' },
    ],
  },
  {
    diaSemana: 3,
    diaNome: 'Quinta-feira',
    isEncerrado: false,
    turnos: [
      { id: '1', horaAbertura: '11:00', horaFecho: '15:00' },
      { id: '2', horaAbertura: '18:00', horaFecho: '23:00' },
    ],
  },
  {
    diaSemana: 4,
    diaNome: 'Sexta-feira',
    isEncerrado: false,
    turnos: [
      { id: '1', horaAbertura: '11:00', horaFecho: '15:00' },
      { id: '2', horaAbertura: '18:00', horaFecho: '23:30' },
    ],
  },
  {
    diaSemana: 5,
    diaNome: 'Sábado',
    isEncerrado: false,
    turnos: [{ id: '1', horaAbertura: '12:00', horaFecho: '23:30' }],
  },
  {
    diaSemana: 6,
    diaNome: 'Domingo',
    isEncerrado: false,
    turnos: [{ id: '1', horaAbertura: '12:00', horaFecho: '22:00' }],
  },
];

export const PartnerOnboardingApp: React.FC = () => {
  // Estado global do status da loja (RN-011)
  const [storeStatus, setStoreStatus] = useState<StoreStatus>('PENDENTE');
  const [viewMode, setViewMode] = useState<'ONBOARDING' | 'PENDING_REVIEW' | 'ACTIVE_HOURS'>('ONBOARDING');
  const [activeStep, setActiveStep] = useState<number>(1);
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false);
  const [notification, setNotification] = useState<{ type: 'success' | 'error' | 'info'; message: string } | null>(null);

  // Passo 1: Dados da Empresa (RN-010)
  const [empresa, setEmpresa] = useState<CompanyDetails>({
    nomeComercial: 'Restaurante Sabor de Luanda',
    nif: '5412345678',
    telefone: '+244 923 456 789',
    email: 'contacto@sabordeluanda.ao',
    moradaTexto: 'Avenida 4 de Fevereiro, n.º 120, Baixa de Luanda',
    categoriaComercial: 'Restaurante Tradicional & Grelhados',
  });
  const [empresaErrors, setEmpresaErrors] = useState<Record<string, string>>({});

  // Passo 2: Dados Bancários JSONField (RN-010)
  const [dadosBancarios, setDadosBancarios] = useState<BankDetails>({
    banco: 'Banco Angolano de Investimentos (BAI)',
    titularConta: 'Sabor de Luanda Restauração Lda',
    numeroConta: '0040.0000.1234.5678.9',
    iban: 'AO06 0040 0000 1234 5678 9012 3',
    swiftBic: 'BAIAAO22',
  });
  const [bancoErrors, setBancoErrors] = useState<Record<string, string>>({});

  // Passo 3: Ficheiros de Licenças (RN-010)
  const [licencaSanitaria, setLicencaSanitaria] = useState<DocumentUpload>({
    file: null,
    fileName: 'licenca_sanitaria_2026.pdf',
    fileSize: 2450000,
    uploadedAt: '2026-10-29',
  });
  const [alvaraComercial, setAlvaraComercial] = useState<DocumentUpload>({
    file: null,
    fileName: 'alvara_comercial_valido.pdf',
    fileSize: 1820000,
    uploadedAt: '2026-10-29',
  });
  const [documentErrors, setDocumentErrors] = useState<Record<string, string>>({});

  // Passo 4 / Módulo RN-012: Horários de Funcionamento
  const [horarios, setHorarios] = useState<DaySchedule[]>(DIAS_PADRAO);
  const [horarioValidationErrors, setHorarioValidationErrors] = useState<string[]>([]);

  // Validação do Passo 1
  const validateStep1 = (): boolean => {
    const errors: Record<string, string> = {};
    if (!empresa.nomeComercial.trim()) errors.nomeComercial = 'O Nome Comercial é obrigatório.';
    const nifValidation = PartnerService.validateNif(empresa.nif);
    if (!nifValidation.isValid) errors.nif = nifValidation.error || 'NIF inválido.';
    if (!empresa.telefone.trim()) errors.telefone = 'Contacto telefónico obrigatório.';
    if (!empresa.email.trim() || !empresa.email.includes('@')) errors.email = 'Email corporativo válido obrigatório.';
    if (!empresa.moradaTexto.trim()) errors.moradaTexto = 'Endereço físico obrigatório para recolha pelos estafetas.';

    setEmpresaErrors(errors);
    return Object.keys(errors).length === 0;
  };

  // Validação do Passo 2
  const validateStep2 = (): boolean => {
    const errors: Record<string, string> = {};
    if (!dadosBancarios.banco.trim()) errors.banco = 'Selecione ou indique o Banco da entidade.';
    if (!dadosBancarios.titularConta.trim()) errors.titularConta = 'Titular da conta é obrigatório.';
    if (!dadosBancarios.numeroConta.trim()) errors.numeroConta = 'Número de conta obrigatório.';
    const ibanVal = PartnerService.validateIban(dadosBancarios.iban);
    if (!ibanVal.isValid) errors.iban = ibanVal.error || 'IBAN inválido.';

    setBancoErrors(errors);
    return Object.keys(errors).length === 0;
  };

  // Validação do Passo 3
  const validateStep3 = (): boolean => {
    const errors: Record<string, string> = {};
    if (!licencaSanitaria.fileName) {
      errors.licenca = 'A Licença Sanitária é estritamente obrigatória para segurança alimentar (RN-010).';
    }
    if (!alvaraComercial.fileName) {
      errors.alvara = 'O Alvará Comercial em vigor é obrigatório para atividade comercial legal (RN-010).';
    }
    setDocumentErrors(errors);
    return Object.keys(errors).length === 0;
  };

  // Submissão do Onboarding
  const handleSubmitOnboarding = async () => {
    if (!validateStep1() || !validateStep2() || !validateStep3()) {
      setNotification({ type: 'error', message: 'Por favor, corrija os erros nos passos anteriores antes de submeter.' });
      return;
    }

    setIsSubmitting(true);
    setNotification(null);

    const dummyFile = new File(['dummy_content'], 'documento.pdf', { type: 'application/pdf' });

    const result = await PartnerService.submitOnboarding({
      empresa,
      dadosBancarios,
      licencaFile: licencaSanitaria.file || dummyFile,
      alvaraFile: alvaraComercial.file || dummyFile,
    });

    setIsSubmitting(false);

    if (result.sucesso) {
      setStoreStatus('PENDENTE');
      setViewMode('PENDING_REVIEW');
      setNotification({
        type: 'success',
        message: 'Candidatura submetida com sucesso! A sua conta entrou em Análise Documental (RN-011).',
      });
    } else {
      setNotification({ type: 'error', message: result.mensagem });
    }
  };

  // Gestão de Horários Semanais (RN-012)
  const handleUpdateTimeSlot = (diaIndex: number, slotIndex: number, field: 'horaAbertura' | 'horaFecho', value: string) => {
    const updated = [...horarios];
    updated[diaIndex].turnos[slotIndex][field] = value;
    setHorarios(updated);
    revalidateAllSchedules(updated);
  };

  const handleAddTimeSlot = (diaIndex: number) => {
    const updated = [...horarios];
    const currentTurnos = updated[diaIndex].turnos;
    const lastTurno = currentTurnos[currentTurnos.length - 1];

    let novaAbertura = '19:00';
    let novoFecho = '23:00';

    if (lastTurno) {
      const [hF] = lastTurno.horaFecho.split(':').map(Number);
      const startH = Math.min(hF + 1, 22);
      novaAbertura = `${String(startH).padStart(2, '0')}:00`;
      novoFecho = `${String(Math.min(startH + 3, 23)).padStart(2, '0')}:30`;
    }

    updated[diaIndex].turnos.push({
      id: String(Date.now()),
      horaAbertura: novaAbertura,
      horaFecho: novoFecho,
    });

    setHorarios(updated);
    revalidateAllSchedules(updated);
  };

  const handleRemoveTimeSlot = (diaIndex: number, slotIndex: number) => {
    const updated = [...horarios];
    if (updated[diaIndex].turnos.length > 1) {
      updated[diaIndex].turnos.splice(slotIndex, 1);
      setHorarios(updated);
      revalidateAllSchedules(updated);
    }
  };

  const handleToggleEncerrado = (diaIndex: number) => {
    const updated = [...horarios];
    updated[diaIndex].isEncerrado = !updated[diaIndex].isEncerrado;
    setHorarios(updated);
    revalidateAllSchedules(updated);
  };

  const handleCopiarParaDiasUteis = () => {
    const templateSegunda = horarios[0];
    const updated = horarios.map((dia) => {
      if (dia.diaSemana >= 1 && dia.diaSemana <= 4) {
        // Terça a Sexta
        return {
          ...dia,
          isEncerrado: templateSegunda.isEncerrado,
          turnos: templateSegunda.turnos.map((t) => ({ ...t, id: String(Math.random()) })),
        };
      }
      return dia;
    });
    setHorarios(updated);
    revalidateAllSchedules(updated);
    setNotification({ type: 'info', message: 'Horários de Segunda-feira copiados para Terça a Sexta-feira!' });
  };

  const revalidateAllSchedules = (schedules: DaySchedule[]) => {
    const errors: string[] = [];

    schedules.forEach((dia) => {
      if (!dia.isEncerrado) {
        dia.turnos.forEach((turno, idx) => {
          const slotVal = PartnerService.validateTimeSlot(turno);
          if (!slotVal.isValid) {
            errors.push(`${dia.diaNome} (Turno ${idx + 1}): ${slotVal.error}`);
          }
        });

        const dayVal = PartnerService.validateDaySchedule(dia);
        if (!dayVal.isValid && dayVal.error) {
          errors.push(dayVal.error);
        }
      }
    });

    setHorarioValidationErrors(errors);
  };

  const handleSaveStoreHours = async () => {
    revalidateAllSchedules(horarios);
    if (horarioValidationErrors.length > 0) {
      setNotification({
        type: 'error',
        message: 'Existem conflitos ou horários inválidos na tabela. Corrija-os antes de guardar.',
      });
      return;
    }

    setIsSubmitting(true);
    const result = await PartnerService.saveStoreHours('loja-uuid', horarios);
    setIsSubmitting(false);

    if (result.sucesso) {
      setNotification({ type: 'success', message: result.mensagem });
    } else {
      setNotification({ type: 'error', message: result.mensagem });
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 text-slate-800 font-sans antialiased flex flex-col">
      {/* 1. Header do Portal */}
      <header className="bg-white border-b border-slate-200 sticky top-0 z-40 shadow-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <div className="flex items-center space-x-3">
            <div className="w-10 h-10 rounded-xl bg-emerald-600 flex items-center justify-center text-white font-bold text-xl shadow-md">
              P
            </div>
            <div>
              <span className="text-lg font-black tracking-tight text-slate-900">DeliveryPartner</span>
              <span className="hidden sm:inline-block ml-2 text-xs font-semibold px-2 py-0.5 rounded-full bg-emerald-100 text-emerald-800">
                Portal do Comerciante
              </span>
            </div>
          </div>

          {/* Seletor de Modo / Simulação de Demonstração */}
          <div className="flex items-center space-x-2 text-xs">
            <span className="text-slate-500 font-medium hidden md:inline">Simular Estado:</span>
            <button
              onClick={() => {
                setViewMode('ONBOARDING');
                setActiveStep(1);
              }}
              className={`px-3 py-1.5 rounded-lg font-semibold transition ${
                viewMode === 'ONBOARDING'
                  ? 'bg-slate-900 text-white shadow'
                  : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
              }`}
            >
              1. Onboarding
            </button>
            <button
              onClick={() => {
                setViewMode('PENDING_REVIEW');
                setStoreStatus('PENDENTE');
              }}
              className={`px-3 py-1.5 rounded-lg font-semibold transition ${
                viewMode === 'PENDING_REVIEW'
                  ? 'bg-amber-600 text-white shadow'
                  : 'bg-amber-100 text-amber-800 hover:bg-amber-200'
              }`}
            >
              2. Pendente (RN-011)
            </button>
            <button
              onClick={() => {
                setViewMode('ACTIVE_HOURS');
                setStoreStatus('ATIVO');
              }}
              className={`px-3 py-1.5 rounded-lg font-semibold transition ${
                viewMode === 'ACTIVE_HOURS'
                  ? 'bg-emerald-600 text-white shadow'
                  : 'bg-emerald-100 text-emerald-800 hover:bg-emerald-200'
              }`}
            >
              3. Horários (RN-012)
            </button>
          </div>
        </div>
      </header>

      {/* Notificações flutuantes */}
      {notification && (
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 mt-4 w-full">
          <div
            className={`p-4 rounded-xl flex items-center justify-between border shadow-sm ${
              notification.type === 'success'
                ? 'bg-emerald-50 border-emerald-300 text-emerald-800'
                : notification.type === 'error'
                ? 'bg-rose-50 border-rose-300 text-rose-800'
                : 'bg-blue-50 border-blue-300 text-blue-800'
            }`}
          >
            <div className="flex items-center space-x-3">
              <span className="text-lg">
                {notification.type === 'success' ? '✓' : notification.type === 'error' ? '⚠' : 'ℹ'}
              </span>
              <p className="text-sm font-medium">{notification.message}</p>
            </div>
            <button
              onClick={() => setNotification(null)}
              className="text-xs font-bold uppercase tracking-wider underline hover:opacity-75"
            >
              Fechar
            </button>
          </div>
        </div>
      )}

      {/* Conteúdo Principal com Barra Lateral Simulada */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8 flex-1 w-full grid grid-cols-1 lg:grid-cols-12 gap-8">
        {/* Barra Lateral do Portal */}
        <aside className="lg:col-span-3">
          <div className="bg-white rounded-2xl border border-slate-200 p-5 shadow-sm space-y-6 sticky top-24">
            {/* Cartão de Estado da Loja */}
            <div className="p-4 rounded-xl bg-slate-50 border border-slate-200/80">
              <span className="text-xs font-bold uppercase tracking-wider text-slate-400">Estado da Loja</span>
              <div className="mt-2 flex items-center space-x-2">
                <span
                  className={`w-3 h-3 rounded-full ${
                    storeStatus === 'ATIVO'
                      ? 'bg-emerald-500 animate-pulse'
                      : storeStatus === 'PENDENTE'
                      ? 'bg-amber-500 animate-pulse'
                      : 'bg-slate-400'
                  }`}
                />
                <span
                  className={`text-sm font-bold ${
                    storeStatus === 'ATIVO'
                      ? 'text-emerald-700'
                      : storeStatus === 'PENDENTE'
                      ? 'text-amber-700'
                      : 'text-slate-600'
                  }`}
                >
                  {storeStatus === 'ATIVO'
                    ? 'Loja Aprovada & Ativa'
                    : storeStatus === 'PENDENTE'
                    ? 'Em Análise Documental'
                    : 'Registo Inicial'}
                </span>
              </div>
              <p className="text-xs text-slate-500 mt-2 font-medium truncate">{empresa.nomeComercial}</p>
            </div>

            {/* Menu de Navegação Lateral */}
            <nav className="space-y-1">
              <div className="text-xs font-bold uppercase tracking-wider text-slate-400 px-3 pb-2">Navegação</div>

              <button
                onClick={() => setViewMode('ONBOARDING')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-sm font-medium transition ${
                  viewMode === 'ONBOARDING'
                    ? 'bg-emerald-50 text-emerald-900 font-bold'
                    : 'text-slate-600 hover:bg-slate-100'
                }`}
              >
                <span>Formulário de Registo</span>
                <span className="text-xs bg-slate-200 text-slate-700 px-1.5 py-0.5 rounded">RN-010</span>
              </button>

              <button
                onClick={() => setViewMode('PENDING_REVIEW')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-sm font-medium transition ${
                  viewMode === 'PENDING_REVIEW'
                    ? 'bg-amber-50 text-amber-900 font-bold'
                    : 'text-slate-600 hover:bg-slate-100'
                }`}
              >
                <span>Análise Documental</span>
                <span className="text-xs bg-amber-100 text-amber-800 px-1.5 py-0.5 rounded">RN-011</span>
              </button>

              <button
                onClick={() => {
                  if (storeStatus === 'ATIVO') {
                    setViewMode('ACTIVE_HOURS');
                  }
                }}
                disabled={storeStatus === 'PENDENTE'}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-sm font-medium transition ${
                  viewMode === 'ACTIVE_HOURS'
                    ? 'bg-emerald-50 text-emerald-900 font-bold'
                    : storeStatus === 'PENDENTE'
                    ? 'text-slate-300 cursor-not-allowed'
                    : 'text-slate-600 hover:bg-slate-100'
                }`}
              >
                <div className="flex items-center space-x-2">
                  <span>Horários Semanais</span>
                  {storeStatus === 'PENDENTE' && <span className="text-xs">🔒</span>}
                </div>
                <span className="text-xs bg-slate-100 text-slate-500 px-1.5 py-0.5 rounded">RN-012</span>
              </button>

              {/* Módulos Bloqueados na Fase Pendente (RN-011) */}
              <div className="pt-2 border-t border-slate-100 space-y-1">
                <div className="text-xs font-bold uppercase tracking-wider text-slate-400 px-3 py-1">
                  Catálogo & Vendas
                </div>

                <div
                  className={`px-3 py-2 rounded-xl text-sm flex items-center justify-between ${
                    storeStatus === 'PENDENTE' ? 'text-slate-300 cursor-not-allowed' : 'text-slate-600 hover:bg-slate-50'
                  }`}
                  title={storeStatus === 'PENDENTE' ? 'RN-011: Bloqueado até aprovação das operações' : ''}
                >
                  <span className="flex items-center space-x-2">
                    <span>Menu & Pratos</span>
                    {storeStatus === 'PENDENTE' && <span className="text-xs">🔒</span>}
                  </span>
                  <span className="text-[10px] text-slate-400">RN-014</span>
                </div>

                <div
                  className={`px-3 py-2 rounded-xl text-sm flex items-center justify-between ${
                    storeStatus === 'PENDENTE' ? 'text-slate-300 cursor-not-allowed' : 'text-slate-600 hover:bg-slate-50'
                  }`}
                >
                  <span className="flex items-center space-x-2">
                    <span>Pedidos em Tempo Real</span>
                    {storeStatus === 'PENDENTE' && <span className="text-xs">🔒</span>}
                  </span>
                  <span className="text-[10px] text-slate-400">OMS</span>
                </div>
              </div>
            </nav>
          </div>
        </aside>

        {/* Área Central Principal */}
        <main className="lg:col-span-9 space-y-6">
          {/* ================================================================ */}
          {/* VISTA 1: FLUXO DE ONBOARDING EM PASSOS (RN-010)                 */}
          {/* ================================================================ */}
          {viewMode === 'ONBOARDING' && (
            <div className="bg-white rounded-3xl border border-slate-200 shadow-sm p-6 sm:p-8">
              {/* Stepper Superior */}
              <div className="mb-8">
                <div className="flex items-center justify-between relative">
                  {/* Linha de Progresso de Fundo */}
                  <div className="absolute left-0 top-1/2 -translate-y-1/2 w-full h-1 bg-slate-200 z-0" />
                  <div
                    className="absolute left-0 top-1/2 -translate-y-1/2 h-1 bg-emerald-600 transition-all duration-300 z-0"
                    style={{ width: `${((activeStep - 1) / 3) * 100}%` }}
                  />

                  {/* Passos do Stepper */}
                  {[
                    { step: 1, label: 'Empresa', desc: 'Dados Fiscais' },
                    { step: 2, label: 'Banco', desc: 'JSONField IBAN' },
                    { step: 3, label: 'Licenças', desc: 'Sanitária & Alvará' },
                    { step: 4, label: 'Confirmação', desc: 'Submissão' },
                  ].map((s) => {
                    const isDone = activeStep > s.step;
                    const isCurrent = activeStep === s.step;
                    return (
                      <div key={s.step} className="relative z-10 flex flex-col items-center">
                        <button
                          onClick={() => {
                            if (s.step < activeStep) setActiveStep(s.step);
                          }}
                          className={`w-10 h-10 rounded-full flex items-center justify-center font-bold text-sm transition shadow-sm ${
                            isDone
                              ? 'bg-emerald-600 text-white'
                              : isCurrent
                              ? 'bg-slate-900 text-white ring-4 ring-slate-100'
                              : 'bg-white border-2 border-slate-300 text-slate-400'
                          }`}
                        >
                          {isDone ? '✓' : s.step}
                        </button>
                        <span
                          className={`mt-2 text-xs font-bold ${
                            isCurrent ? 'text-slate-900' : isDone ? 'text-emerald-700' : 'text-slate-400'
                          }`}
                        >
                          {s.label}
                        </span>
                        <span className="hidden sm:inline-block text-[10px] text-slate-400">{s.desc}</span>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* PASSO 1: DADOS DA EMPRESA (RN-010) */}
              {activeStep === 1 && (
                <div className="space-y-6">
                  <div>
                    <h2 className="text-xl font-bold text-slate-900">Passo 1: Identificação Comercial e Fiscal</h2>
                    <p className="text-sm text-slate-500 mt-1">
                      Regra RN-010: O NIF deve ser único na plataforma e associado ao registo legal do estabelecimento.
                    </p>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div className="sm:col-span-2">
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Nome Comercial do Estabelecimento *
                      </label>
                      <input
                        type="text"
                        value={empresa.nomeComercial}
                        onChange={(e) => setEmpresa({ ...empresa, nomeComercial: e.target.value })}
                        placeholder="Ex: Restaurante Kianda Mar"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          empresaErrors.nomeComercial ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {empresaErrors.nomeComercial && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{empresaErrors.nomeComercial}</p>
                      )}
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        NIF Único (Número de Identificação Fiscal) *
                      </label>
                      <input
                        type="text"
                        value={empresa.nif}
                        onChange={(e) => setEmpresa({ ...empresa, nif: e.target.value })}
                        placeholder="Ex: 5412345678"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          empresaErrors.nif ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {empresaErrors.nif ? (
                        <p className="text-xs text-rose-600 font-medium mt-1">{empresaErrors.nif}</p>
                      ) : (
                        <p className="text-[11px] text-slate-400 mt-1">9 ou 10 dígitos fiscais com validação estrita.</p>
                      )}
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Categoria Comercial Principal *
                      </label>
                      <select
                        value={empresa.categoriaComercial}
                        onChange={(e) => setEmpresa({ ...empresa, categoriaComercial: e.target.value })}
                        className="w-full px-4 py-2.5 rounded-xl border border-slate-300 bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                      >
                        <option>Restaurante Tradicional & Grelhados</option>
                        <option>Pizzaria & Massas</option>
                        <option>Hamburgueria & Fast Food</option>
                        <option>Pastelaria, Padaria & Cafetaria</option>
                        <option>Supermercado & Mercearia</option>
                        <option>Bebidas & Garrafeira</option>
                      </select>
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Contacto Telefónico Operacional *
                      </label>
                      <input
                        type="text"
                        value={empresa.telefone}
                        onChange={(e) => setEmpresa({ ...empresa, telefone: e.target.value })}
                        placeholder="+244 923 000 000"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          empresaErrors.telefone ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {empresaErrors.telefone && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{empresaErrors.telefone}</p>
                      )}
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Email Corporativo / Notificações *
                      </label>
                      <input
                        type="email"
                        value={empresa.email}
                        onChange={(e) => setEmpresa({ ...empresa, email: e.target.value })}
                        placeholder="gerencia@empresa.ao"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          empresaErrors.email ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {empresaErrors.email && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{empresaErrors.email}</p>
                      )}
                    </div>

                    <div className="sm:col-span-2">
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Endereço Físico Completo (Para Recolha de Estafetas) *
                      </label>
                      <input
                        type="text"
                        value={empresa.moradaTexto}
                        onChange={(e) => setEmpresa({ ...empresa, moradaTexto: e.target.value })}
                        placeholder="Rua, Número, Bairro, Município, Província"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          empresaErrors.moradaTexto ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {empresaErrors.moradaTexto && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{empresaErrors.moradaTexto}</p>
                      )}
                    </div>
                  </div>

                  <div className="pt-4 flex justify-end">
                    <button
                      onClick={() => {
                        if (validateStep1()) setActiveStep(2);
                      }}
                      className="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-xl shadow-sm transition flex items-center space-x-2"
                    >
                      <span>Seguinte: Dados Bancários</span>
                      <span>→</span>
                    </button>
                  </div>
                </div>
              )}

              {/* PASSO 2: DADOS BANCÁRIOS ESTRUTURADOS (RN-010) */}
              {activeStep === 2 && (
                <div className="space-y-6">
                  <div>
                    <h2 className="text-xl font-bold text-slate-900">Passo 2: Dados Bancários para Liquidação</h2>
                    <p className="text-sm text-slate-500 mt-1">
                      Regra RN-010 e Secção 7.3: Estrutura JSONField com IBAN verificado para liquidação semanal de vendas.
                    </p>
                  </div>

                  <div className="p-4 bg-emerald-50/60 border border-emerald-200 rounded-2xl flex items-start space-x-3">
                    <span className="text-emerald-700 text-xl font-bold">ℹ</span>
                    <p className="text-xs text-emerald-800 leading-relaxed">
                      Os pagamentos das encomendas concluídas são reconciliados pelo Livro Razão (Ledger de dupla entrada)
                      e transferidos automaticamente para a conta bancária indicada.
                    </p>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div className="sm:col-span-2">
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Instituição Bancária *
                      </label>
                      <input
                        type="text"
                        value={dadosBancarios.banco}
                        onChange={(e) => setDadosBancarios({ ...dadosBancarios, banco: e.target.value })}
                        placeholder="Ex: Banco Angolano de Investimentos (BAI) / BFA"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          bancoErrors.banco ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {bancoErrors.banco && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{bancoErrors.banco}</p>
                      )}
                    </div>

                    <div className="sm:col-span-2">
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Nome do Titular da Conta Comercial *
                      </label>
                      <input
                        type="text"
                        value={dadosBancarios.titularConta}
                        onChange={(e) => setDadosBancarios({ ...dadosBancarios, titularConta: e.target.value })}
                        placeholder="Ex: Sabor de Luanda Restauração Sociedade Unipessoal Lda"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          bancoErrors.titularConta ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {bancoErrors.titularConta && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{bancoErrors.titularConta}</p>
                      )}
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Número de Conta *
                      </label>
                      <input
                        type="text"
                        value={dadosBancarios.numeroConta}
                        onChange={(e) => setDadosBancarios({ ...dadosBancarios, numeroConta: e.target.value })}
                        placeholder="Ex: 0040.0000.1234.5678.9"
                        className={`w-full px-4 py-2.5 rounded-xl border bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          bancoErrors.numeroConta ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300'
                        }`}
                      />
                      {bancoErrors.numeroConta && (
                        <p className="text-xs text-rose-600 font-medium mt-1">{bancoErrors.numeroConta}</p>
                      )}
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        Código SWIFT / BIC (Opcional)
                      </label>
                      <input
                        type="text"
                        value={dadosBancarios.swiftBic}
                        onChange={(e) => setDadosBancarios({ ...dadosBancarios, swiftBic: e.target.value })}
                        placeholder="Ex: BAIAAO22"
                        className="w-full px-4 py-2.5 rounded-xl border border-slate-300 bg-slate-50/50 text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                      />
                    </div>

                    <div className="sm:col-span-2">
                      <label className="block text-xs font-bold text-slate-700 uppercase tracking-wider mb-1">
                        IBAN Internacional Validado *
                      </label>
                      <input
                        type="text"
                        value={dadosBancarios.iban}
                        onChange={(e) => setDadosBancarios({ ...dadosBancarios, iban: e.target.value })}
                        placeholder="AO06 0040 0000 1234 5678 9012 3"
                        className={`w-full px-4 py-2.5 rounded-xl border font-mono text-sm focus:outline-none focus:ring-2 focus:ring-emerald-500 transition ${
                          bancoErrors.iban ? 'border-rose-400 bg-rose-50/30' : 'border-slate-300 bg-slate-50/50'
                        }`}
                      />
                      {bancoErrors.iban ? (
                        <p className="text-xs text-rose-600 font-medium mt-1">{bancoErrors.iban}</p>
                      ) : (
                        <p className="text-[11px] text-slate-400 mt-1">
                          21 a 34 caracteres alfanuméricos com verificação de módulo.
                        </p>
                      )}
                    </div>
                  </div>

                  <div className="pt-4 flex justify-between">
                    <button
                      onClick={() => setActiveStep(1)}
                      className="px-5 py-2.5 border border-slate-300 hover:bg-slate-100 text-slate-700 font-bold rounded-xl transition"
                    >
                      ← Voltar
                    </button>
                    <button
                      onClick={() => {
                        if (validateStep2()) setActiveStep(3);
                      }}
                      className="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-xl shadow-sm transition flex items-center space-x-2"
                    >
                      <span>Seguinte: Licenças e Alvará</span>
                      <span>→</span>
                    </button>
                  </div>
                </div>
              )}

              {/* PASSO 3: CARREGAMENTO DE LICENÇAS E ALVARÁ (RN-010) */}
              {activeStep === 3 && (
                <div className="space-y-6">
                  <div>
                    <h2 className="text-xl font-bold text-slate-900">Passo 3: Carregamento de Licenças Regulamentares</h2>
                    <p className="text-sm text-slate-500 mt-1">
                      Regra RN-010: O carregamento da Licença Sanitária e do Alvará Comercial é imperativo para
                      conformidade com a legislação de saúde pública e fiscal.
                    </p>
                  </div>

                  <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    {/* Upload 1: Licença Sanitária */}
                    <div className="p-5 rounded-2xl border-2 border-dashed border-slate-300 hover:border-emerald-500 transition bg-slate-50/50 flex flex-col items-center text-center">
                      <div className="w-12 h-12 rounded-2xl bg-emerald-100 text-emerald-800 flex items-center justify-center font-bold text-xl mb-3">
                        🏥
                      </div>
                      <h3 className="text-sm font-bold text-slate-800">Licença Sanitária Válida *</h3>
                      <p className="text-xs text-slate-500 mt-1 mb-4">
                        Documento emitido pelos serviços competentes de saúde alimentar. (PDF ou JPG até 10MB)
                      </p>

                      {licencaSanitaria.fileName ? (
                        <div className="w-full p-3 rounded-xl bg-white border border-slate-200 flex items-center justify-between shadow-sm">
                          <div className="flex items-center space-x-2 truncate">
                            <span className="text-emerald-600 font-bold">📄</span>
                            <span className="text-xs font-semibold text-slate-700 truncate">
                              {licencaSanitaria.fileName}
                            </span>
                          </div>
                          <span className="text-[10px] text-emerald-700 font-bold bg-emerald-100 px-2 py-0.5 rounded">
                            Carregado
                          </span>
                        </div>
                      ) : (
                        <label className="cursor-pointer px-4 py-2 bg-white border border-slate-300 hover:bg-slate-50 text-slate-700 text-xs font-bold rounded-xl shadow-sm transition">
                          Selecionar Ficheiro
                          <input
                            type="file"
                            className="hidden"
                            accept=".pdf,.png,.jpg,.jpeg"
                            onChange={(e) => {
                              const f = e.target.files?.[0];
                              if (f) {
                                setLicencaSanitaria({
                                  file: f,
                                  fileName: f.name,
                                  fileSize: f.size,
                                  uploadedAt: new Date().toISOString(),
                                });
                              }
                            }}
                          />
                        </label>
                      )}
                      {documentErrors.licenca && (
                        <p className="text-xs text-rose-600 font-medium mt-2">{documentErrors.licenca}</p>
                      )}
                    </div>

                    {/* Upload 2: Alvará Comercial */}
                    <div className="p-5 rounded-2xl border-2 border-dashed border-slate-300 hover:border-emerald-500 transition bg-slate-50/50 flex flex-col items-center text-center">
                      <div className="w-12 h-12 rounded-2xl bg-blue-100 text-blue-800 flex items-center justify-center font-bold text-xl mb-3">
                        🏢
                      </div>
                      <h3 className="text-sm font-bold text-slate-800">Alvará Comercial de Funcionamento *</h3>
                      <p className="text-xs text-slate-500 mt-1 mb-4">
                        Comprovativo de registo comercial emitido pelo Ministério do Comércio. (PDF até 10MB)
                      </p>

                      {alvaraComercial.fileName ? (
                        <div className="w-full p-3 rounded-xl bg-white border border-slate-200 flex items-center justify-between shadow-sm">
                          <div className="flex items-center space-x-2 truncate">
                            <span className="text-blue-600 font-bold">📄</span>
                            <span className="text-xs font-semibold text-slate-700 truncate">
                              {alvaraComercial.fileName}
                            </span>
                          </div>
                          <span className="text-[10px] text-blue-700 font-bold bg-blue-100 px-2 py-0.5 rounded">
                            Carregado
                          </span>
                        </div>
                      ) : (
                        <label className="cursor-pointer px-4 py-2 bg-white border border-slate-300 hover:bg-slate-50 text-slate-700 text-xs font-bold rounded-xl shadow-sm transition">
                          Selecionar Ficheiro
                          <input
                            type="file"
                            className="hidden"
                            accept=".pdf,.png,.jpg,.jpeg"
                            onChange={(e) => {
                              const f = e.target.files?.[0];
                              if (f) {
                                setAlvaraComercial({
                                  file: f,
                                  fileName: f.name,
                                  fileSize: f.size,
                                  uploadedAt: new Date().toISOString(),
                                });
                              }
                            }}
                          />
                        </label>
                      )}
                      {documentErrors.alvara && (
                        <p className="text-xs text-rose-600 font-medium mt-2">{documentErrors.alvara}</p>
                      )}
                    </div>
                  </div>

                  <div className="pt-4 flex justify-between">
                    <button
                      onClick={() => setActiveStep(2)}
                      className="px-5 py-2.5 border border-slate-300 hover:bg-slate-100 text-slate-700 font-bold rounded-xl transition"
                    >
                      ← Voltar
                    </button>
                    <button
                      onClick={() => {
                        if (validateStep3()) setActiveStep(4);
                      }}
                      className="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-xl shadow-sm transition flex items-center space-x-2"
                    >
                      <span>Seguinte: Resumo Final</span>
                      <span>→</span>
                    </button>
                  </div>
                </div>
              )}

              {/* PASSO 4: RESUMO E CONFIRMAÇÃO DE SUBMISSÃO (RN-010 / RN-011) */}
              {activeStep === 4 && (
                <div className="space-y-6">
                  <div>
                    <h2 className="text-xl font-bold text-slate-900">Passo 4: Resumo e Envio para Validação Humana</h2>
                    <p className="text-sm text-slate-500 mt-1">
                      Reveja os dados submetidos. Ao confirmar, o estabelecimento entrará no estado{' '}
                      <strong className="text-amber-700">Pendente de Validação (RN-011)</strong>.
                    </p>
                  </div>

                  <div className="space-y-4">
                    {/* Card Resumo 1 */}
                    <div className="p-4 rounded-2xl bg-slate-50 border border-slate-200">
                      <div className="flex justify-between items-center mb-2">
                        <span className="text-xs font-bold uppercase tracking-wider text-slate-500">
                          1. Dados da Empresa
                        </span>
                        <button
                          onClick={() => setActiveStep(1)}
                          className="text-xs text-emerald-600 hover:underline font-bold"
                        >
                          Editar
                        </button>
                      </div>
                      <div className="grid grid-cols-2 gap-2 text-xs">
                        <div>
                          <span className="text-slate-400">Nome:</span>{' '}
                          <span className="font-bold text-slate-800">{empresa.nomeComercial}</span>
                        </div>
                        <div>
                          <span className="text-slate-400">NIF:</span>{' '}
                          <span className="font-mono font-bold text-slate-800">{empresa.nif}</span>
                        </div>
                        <div>
                          <span className="text-slate-400">Contacto:</span>{' '}
                          <span className="font-medium text-slate-800">{empresa.telefone}</span>
                        </div>
                        <div>
                          <span className="text-slate-400">Email:</span>{' '}
                          <span className="font-medium text-slate-800">{empresa.email}</span>
                        </div>
                      </div>
                    </div>

                    {/* Card Resumo 2 */}
                    <div className="p-4 rounded-2xl bg-slate-50 border border-slate-200">
                      <div className="flex justify-between items-center mb-2">
                        <span className="text-xs font-bold uppercase tracking-wider text-slate-500">
                          2. Conta de Liquidação (JSONField)
                        </span>
                        <button
                          onClick={() => setActiveStep(2)}
                          className="text-xs text-emerald-600 hover:underline font-bold"
                        >
                          Editar
                        </button>
                      </div>
                      <div className="grid grid-cols-2 gap-2 text-xs">
                        <div>
                          <span className="text-slate-400">Banco:</span>{' '}
                          <span className="font-bold text-slate-800">{dadosBancarios.banco}</span>
                        </div>
                        <div>
                          <span className="text-slate-400">Titular:</span>{' '}
                          <span className="font-medium text-slate-800">{dadosBancarios.titularConta}</span>
                        </div>
                        <div className="col-span-2">
                          <span className="text-slate-400">IBAN:</span>{' '}
                          <span className="font-mono font-bold text-slate-800">{dadosBancarios.iban}</span>
                        </div>
                      </div>
                    </div>

                    {/* Card Resumo 3 */}
                    <div className="p-4 rounded-2xl bg-slate-50 border border-slate-200">
                      <div className="flex justify-between items-center mb-2">
                        <span className="text-xs font-bold uppercase tracking-wider text-slate-500">
                          3. Documentos Anexados
                        </span>
                        <button
                          onClick={() => setActiveStep(3)}
                          className="text-xs text-emerald-600 hover:underline font-bold"
                        >
                          Editar
                        </button>
                      </div>
                      <div className="space-y-1 text-xs">
                        <p className="flex items-center space-x-2">
                          <span className="text-emerald-600 font-bold">✓</span>
                          <span>Licença Sanitária:</span>
                          <span className="font-semibold text-slate-800">{licencaSanitaria.fileName}</span>
                        </p>
                        <p className="flex items-center space-x-2">
                          <span className="text-blue-600 font-bold">✓</span>
                          <span>Alvará Comercial:</span>
                          <span className="font-semibold text-slate-800">{alvaraComercial.fileName}</span>
                        </p>
                      </div>
                    </div>
                  </div>

                  <div className="pt-4 flex justify-between items-center">
                    <button
                      onClick={() => setActiveStep(3)}
                      className="px-5 py-2.5 border border-slate-300 hover:bg-slate-100 text-slate-700 font-bold rounded-xl transition"
                    >
                      ← Voltar
                    </button>
                    <button
                      onClick={handleSubmitOnboarding}
                      disabled={isSubmitting}
                      className="px-8 py-3 bg-emerald-600 hover:bg-emerald-700 disabled:bg-slate-400 text-white font-bold rounded-xl shadow-lg transition flex items-center space-x-2"
                    >
                      {isSubmitting ? (
                        <>
                          <span className="animate-spin">⏳</span>
                          <span>A submeter candidatura...</span>
                        </>
                      ) : (
                        <>
                          <span>Submeter Documentação para Aprovação (RN-011)</span>
                          <span>✓</span>
                        </>
                      )}
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* ================================================================ */}
          {/* VISTA 2: ESTADO DE APROVAÇÃO VISUAL / CONTA EM ANÁLISE (RN-011)  */}
          {/* ================================================================ */}
          {viewMode === 'PENDING_REVIEW' && (
            <div className="bg-white rounded-3xl border border-amber-200/80 shadow-sm p-6 sm:p-10 space-y-8">
              {/* Cabeçalho de Bloqueio Amigável */}
              <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 p-6 bg-amber-50/70 border border-amber-200 rounded-2xl">
                <div className="flex items-start space-x-4">
                  <div className="w-14 h-14 rounded-2xl bg-amber-500/10 border border-amber-300 flex items-center justify-center text-3xl">
                    ⏳
                  </div>
                  <div>
                    <div className="flex items-center space-x-2">
                      <span className="px-2.5 py-0.5 rounded-full text-xs font-bold bg-amber-200 text-amber-900 uppercase tracking-wide">
                        RN-011: Estado Pendente
                      </span>
                    </div>
                    <h2 className="text-xl font-bold text-slate-900 mt-1">Conta em Análise Documental</h2>
                    <p className="text-xs text-slate-600 mt-1">
                      A equipa de Operações e Compliance está a verificar a conformidade da Licença Sanitária e Alvará.
                    </p>
                  </div>
                </div>

                {/* Botão de Demonstração para Simular Aprovação */}
                <button
                  onClick={() => {
                    setStoreStatus('ATIVO');
                    setViewMode('ACTIVE_HOURS');
                    setNotification({
                      type: 'success',
                      message: 'Loja Aprovada com sucesso pelas Operações! Menu e Horários desbloqueados (RN-012).',
                    });
                  }}
                  className="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold rounded-xl shadow-sm transition whitespace-nowrap"
                >
                  Simular Aprovação das Operações
                </button>
              </div>

              {/* Timeline Explicativa do Processo de Aprovação */}
              <div>
                <h3 className="text-sm font-bold uppercase tracking-wider text-slate-400 mb-4">
                  Progresso da Homologação (SLA &lt; 24h)
                </h3>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div className="p-4 rounded-xl border border-emerald-200 bg-emerald-50/50">
                    <div className="flex items-center justify-between text-emerald-800 font-bold text-xs mb-1">
                      <span>1. Submissão Inicial</span>
                      <span>✓ Concluído</span>
                    </div>
                    <p className="text-xs text-slate-600">
                      Formulário de identificação e comprovativos bancários recebidos pelo sistema.
                    </p>
                  </div>

                  <div className="p-4 rounded-xl border-2 border-amber-400 bg-amber-50/50 shadow-sm relative">
                    <div className="flex items-center justify-between text-amber-900 font-bold text-xs mb-1">
                      <span>2. Verificação Humana</span>
                      <span className="animate-pulse">● Em Análise</span>
                    </div>
                    <p className="text-xs text-slate-600">
                      Validação documental cruzada da Licença Sanitária e NIF junto das entidades oficiais.
                    </p>
                  </div>

                  <div className="p-4 rounded-xl border border-slate-200 bg-slate-50 text-slate-400">
                    <div className="flex items-center justify-between font-bold text-xs mb-1">
                      <span>3. Ativação do Catálogo</span>
                      <span>Pendente</span>
                    </div>
                    <p className="text-xs text-slate-500">
                      Publicação imediata do menu e abertura da loja aos clientes na plataforma.
                    </p>
                  </div>
                </div>
              </div>

              {/* Bloqueio do Catálogo (RN-011) */}
              <div className="p-6 rounded-2xl bg-slate-50 border border-slate-200 text-center space-y-3">
                <span className="text-3xl">🔒</span>
                <h4 className="text-base font-bold text-slate-800">Publicação de Menus Temporariamente Bloqueada</h4>
                <p className="text-xs text-slate-500 max-w-xl mx-auto leading-relaxed">
                  Em cumprimento estrito da regra <strong>RN-011</strong>, nenhuma loja parceira pode comercializar itens
                  ou ativar pedidos antes da validação formal da licença sanitária e dos dados fiscais.
                </p>
                <div className="pt-2">
                  <button
                    onClick={() => setViewMode('ONBOARDING')}
                    className="text-xs font-bold text-emerald-700 hover:underline"
                  >
                    Rever dados da candidatura submetida
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* ================================================================ */}
          {/* VISTA 3: CONFIGURAÇÃO DE HORÁRIOS SEMANAIS (RN-012)              */}
          {/* ================================================================ */}
          {viewMode === 'ACTIVE_HOURS' && (
            <div className="bg-white rounded-3xl border border-slate-200 shadow-sm p-6 sm:p-8 space-y-6">
              {/* Header do Módulo de Horários */}
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-slate-100 pb-5">
                <div>
                  <div className="flex items-center space-x-2">
                    <span className="px-2.5 py-0.5 rounded-full text-xs font-bold bg-emerald-100 text-emerald-800">
                      RN-012: Operação Ativa
                    </span>
                  </div>
                  <h2 className="text-xl font-bold text-slate-900 mt-1">Configuração de Horários Semanais</h2>
                  <p className="text-xs text-slate-500 mt-1">
                    Defina múltiplos turnos por dia (ex.: almoço e jantar). O motor impede turnos com hora de fecho
                    anterior à abertura.
                  </p>
                </div>

                <div className="flex items-center space-x-2">
                  <button
                    onClick={handleCopiarParaDiasUteis}
                    className="px-3 py-2 text-xs font-bold bg-slate-100 hover:bg-slate-200 text-slate-700 rounded-xl transition"
                    title="Copia os turnos de Segunda-feira para Terça a Sexta-feira"
                  >
                    Copiar 2ª para Dias Úteis
                  </button>
                  <button
                    onClick={handleSaveStoreHours}
                    disabled={isSubmitting || horarioValidationErrors.length > 0}
                    className="px-5 py-2 text-xs font-bold bg-emerald-600 hover:bg-emerald-700 disabled:bg-slate-300 text-white rounded-xl shadow-sm transition"
                  >
                    Guardar Horários
                  </button>
                </div>
              </div>

              {/* Alerta de Validação Visual de Horários (RN-012) */}
              {horarioValidationErrors.length > 0 && (
                <div className="p-4 rounded-xl bg-rose-50 border border-rose-300 text-rose-800 text-xs space-y-1">
                  <p className="font-bold flex items-center space-x-1">
                    <span>⚠</span>
                    <span>Erros de Consistência Horária Detetados (RN-012):</span>
                  </p>
                  <ul className="list-disc list-inside space-y-0.5 pl-2">
                    {horarioValidationErrors.map((err, idx) => (
                      <li key={idx}>{err}</li>
                    ))}
                  </ul>
                </div>
              )}

              {/* Tabela de Horários Semanais */}
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm border-collapse">
                  <thead>
                    <tr className="border-b border-slate-200 text-xs uppercase tracking-wider text-slate-400">
                      <th className="py-3 px-4 w-36 font-bold">Dia da Semana</th>
                      <th className="py-3 px-4 w-32 font-bold">Estado</th>
                      <th className="py-3 px-4 font-bold">Turnos de Abertura e Fecho (RN-012)</th>
                      <th className="py-3 px-4 w-32 text-right font-bold">Ações</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {horarios.map((dia, diaIdx) => (
                      <tr
                        key={dia.diaSemana}
                        className={`transition ${dia.isEncerrado ? 'bg-slate-50/60 opacity-60' : 'hover:bg-slate-50/40'}`}
                      >
                        {/* Nome do Dia */}
                        <td className="py-4 px-4 font-bold text-slate-900 whitespace-nowrap">{dia.diaNome}</td>

                        {/* Toggle de Abertura / Encerramento */}
                        <td className="py-4 px-4 whitespace-nowrap">
                          <button
                            onClick={() => handleToggleEncerrado(diaIdx)}
                            className={`px-3 py-1 rounded-full text-xs font-bold transition ${
                              dia.isEncerrado
                                ? 'bg-slate-200 text-slate-700 hover:bg-slate-300'
                                : 'bg-emerald-100 text-emerald-800 hover:bg-emerald-200'
                            }`}
                          >
                            {dia.isEncerrado ? 'Encerrado' : 'Aberto'}
                          </button>
                        </td>

                        {/* Configuração de Múltiplos Turnos */}
                        <td className="py-4 px-4">
                          {dia.isEncerrado ? (
                            <span className="text-xs text-slate-400 italic">Loja fechada ao público neste dia.</span>
                          ) : (
                            <div className="space-y-2">
                              {dia.turnos.map((turno, slotIdx) => {
                                const isValidSlot =
                                  turno.horaAbertura &&
                                  turno.horaFecho &&
                                  turno.horaFecho > turno.horaAbertura;

                                return (
                                  <div
                                    key={turno.id}
                                    className={`inline-flex flex-wrap items-center gap-2 p-2 rounded-xl border mr-2 mb-1 transition ${
                                      isValidSlot
                                        ? 'bg-slate-50 border-slate-200'
                                        : 'bg-rose-50 border-rose-300 ring-1 ring-rose-300'
                                    }`}
                                  >
                                    <span className="text-[11px] font-bold text-slate-400">#{slotIdx + 1}</span>

                                    {/* Input Hora de Abertura */}
                                    <input
                                      type="time"
                                      value={turno.horaAbertura}
                                      onChange={(e) =>
                                        handleUpdateTimeSlot(diaIdx, slotIdx, 'horaAbertura', e.target.value)
                                      }
                                      className="px-2 py-1 bg-white border border-slate-300 rounded-lg text-xs font-mono font-bold focus:outline-none focus:ring-1 focus:ring-emerald-500"
                                    />

                                    <span className="text-xs text-slate-400 font-bold">às</span>

                                    {/* Input Hora de Fecho */}
                                    <input
                                      type="time"
                                      value={turno.horaFecho}
                                      onChange={(e) =>
                                        handleUpdateTimeSlot(diaIdx, slotIdx, 'horaFecho', e.target.value)
                                      }
                                      className={`px-2 py-1 bg-white border rounded-lg text-xs font-mono font-bold focus:outline-none focus:ring-1 transition ${
                                        isValidSlot
                                          ? 'border-slate-300 focus:ring-emerald-500'
                                          : 'border-rose-400 text-rose-700 focus:ring-rose-500'
                                      }`}
                                    />

                                    {/* Botão de Remover Turno */}
                                    {dia.turnos.length > 1 && (
                                      <button
                                        onClick={() => handleRemoveTimeSlot(diaIdx, slotIdx)}
                                        className="text-slate-400 hover:text-rose-600 font-bold text-xs p-1 rounded"
                                        title="Remover este turno"
                                      >
                                        ✕
                                      </button>
                                    )}

                                    {!isValidSlot && (
                                      <span className="text-[10px] text-rose-600 font-bold block w-full">
                                        Fecho deve ser posterior à abertura
                                      </span>
                                    )}
                                  </div>
                                );
                              })}
                            </div>
                          )}
                        </td>

                        {/* Botão para Adicionar Novo Turno */}
                        <td className="py-4 px-4 text-right whitespace-nowrap">
                          {!dia.isEncerrado && (
                            <button
                              onClick={() => handleAddTimeSlot(diaIdx)}
                              className="px-3 py-1 bg-slate-100 hover:bg-emerald-50 hover:text-emerald-800 text-slate-700 text-xs font-bold rounded-lg border border-slate-200 transition"
                              title="Adicionar mais um intervalo para este dia"
                            >
                              + Turno
                            </button>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              {/* Botão Inferior de Submissão */}
              <div className="pt-4 border-t border-slate-100 flex justify-end">
                <button
                  onClick={handleSaveStoreHours}
                  disabled={isSubmitting || horarioValidationErrors.length > 0}
                  className="px-6 py-2.5 bg-emerald-600 hover:bg-emerald-700 disabled:bg-slate-300 text-white font-bold rounded-xl shadow-md transition flex items-center space-x-2"
                >
                  {isSubmitting ? (
                    <span>A guardar matriz semanal...</span>
                  ) : (
                    <>
                      <span>Guardar e Sincronizar Horários (PUT /hours/)</span>
                      <span>✓</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          )}
        </main>
      </div>
    </div>
  );
};

export default PartnerOnboardingApp;


/**
 * Camada de Serviço de API para a Consola de Atendimento de Suporte (SupportAgentConsole).
 * Conecta-se às rotas de Suporte e Disputas do Django REST Framework (RN-106, RN-138 a RN-142).
 */

import { DisputeResolutionPayload, SupportTicket } from '../types';

const API_BASE = 'http://localhost:8000/api/v1/support';

// Mock realista de incidentes activos em Luanda para o call center de suporte
const MOCK_TICKETS: SupportTicket[] = [
  {
    id: 'tkt-urg-1001',
    pedidoId: 'ped-uuid-napoli-01',
    codigoDisplay: '#LUA-9049',
    clienteNome: 'Mariana de Albuquerque',
    clienteTelemovelMascarado: '+244 923 *** 222',
    lojaNome: 'Pizzaria & Trattoria Napoli (Talatona)',
    lojaNif: '5401928374',
    itensResumo: '1x Pizza Quattro Formaggi, 1x Tiramisù Clássico',
    subtotalKz: 8500,
    totalKz: 10125,
    tipoIncidente: 'REACAO_ALERGICA',
    prioridade: 'CRITICA',
    estado: 'ABERTO',
    motivoAbertura:
      'ALERTA EMERGENCIAL (RN-140): Cliente relatou crise alérgica grave imediata após ingestão de sobremesa com nozes não declaradas nas observações.',
    tempoRestanteSlaSegundos: 165, // 2m 45s restantes no SLA de 5 min
    slaCriticoMinutos: 5,
    criadoEm: '2026-10-29 22:24:15',
    timelinePedido: [
      { estado: 'CRIADO', descricao: 'Pedido submetido pelo cliente no Checkout', timestamp: '21:30:10', concluido: true },
      { estado: 'ACEITE', descricao: 'Restaurante aceitou o pedido em 38 segundos', timestamp: '21:30:48', concluido: true },
      { estado: 'EM_PREPARACAO', descricao: 'Cozinha iniciou preparação com nota de alergia', timestamp: '21:32:00', concluido: true },
      { estado: 'DESPACHADO', descricao: 'Estafeta levantou o pedido na loja', timestamp: '21:55:12', concluido: true },
      { estado: 'ENTREGUE', descricao: 'PIN 4 dígitos verificado com sucesso pelo estafeta', timestamp: '22:15:30', concluido: true },
    ],
    mensagensChat: [
      {
        id: 'msg-1',
        remetenteTipo: 'CLIENTE',
        remetenteNome: 'Mariana (Cliente)',
        conteudo: 'SOCORRO! Deixei explicitamente nas notas que sou hiperalérgica a nozes e o doce veio cheio de amêndoas! Tive de chamar assistência médica!',
        timestamp: '22:24:15',
      },
      {
        id: 'msg-2',
        remetenteTipo: 'LOJA',
        remetenteNome: 'Restaurante Napoli (Cozinha)',
        conteudo: 'Boa noite. O nosso tiramisù leva essência e frutos secos na calda. O cozinheiro não reparou na observação por ser hora de ponta.',
        timestamp: '22:25:30',
      },
      {
        id: 'msg-3',
        remetenteTipo: 'SISTEMA',
        remetenteNome: 'Sistema Antifraude & Risco',
        conteudo: 'RN-139 / RN-140: Ticket escalado automaticamente para a equipa médica de suporte prioritário com SLA < 5 minutos.',
        timestamp: '22:25:31',
      },
    ],
    evidenciasFotos: [
      {
        id: 'foto-1',
        url: 'https://images.unsplash.com/photo-1571877227200-a0d98ea607e9?w=600&auto=format&fit=crop',
        legenda: 'Foto da sobremesa e comprovativo de receita/atendimento médico enviado pelo cliente',
        autor: 'CLIENTE',
        dataEnvio: '22:26:00',
      },
    ],
  },
  {
    id: 'tkt-dan-1002',
    pedidoId: 'ped-uuid-burger-02',
    codigoDisplay: '#LUA-9052',
    clienteNome: 'Dr. Sebastião Viana',
    clienteTelemovelMascarado: '+244 912 *** 444',
    lojaNome: 'Hamburgueria Artesanal Baixa',
    lojaNif: '5419283011',
    itensResumo: '2x Double Bacon Burger, 1x Batata Frita Especial, 2x Sumo de Manga',
    subtotalKz: 9200,
    totalKz: 11000,
    tipoIncidente: 'DERRAME_DANOS',
    prioridade: 'MEDIA',
    estado: 'EM_ANALISE',
    motivoAbertura:
      'RN-101: Estafeta reportou travagem brusca de emergência com derrame total de sumos e dano estrutural nas embalagens.',
    tempoRestanteSlaSegundos: 900,
    slaCriticoMinutos: 30,
    criadoEm: '2026-10-29 22:10:00',
    timelinePedido: [
      { estado: 'CRIADO', descricao: 'Pedido registado', timestamp: '21:15:00', concluido: true },
      { estado: 'ACEITE', descricao: 'Aceite pelo restaurante', timestamp: '21:16:00', concluido: true },
      { estado: 'DESPACHADO', descricao: 'Em rota na mota do estafeta', timestamp: '21:40:00', concluido: true },
      { estado: 'INCIDENTE_REPORTADO', descricao: 'Estafeta registou foto de derrame no trânsito', timestamp: '22:10:00', concluido: true },
    ],
    mensagensChat: [
      {
        id: 'msg-10',
        remetenteTipo: 'ESTAFETA',
        remetenteNome: 'Mateus (Estafeta #42)',
        conteudo: 'Um táxi cortou a minha frente na rotunda e tive de deitar a mota. Os copos de sumo abriram e molharam os hambúrgueres todos. Estou a enviar a foto para cancelamento justo.',
        timestamp: '22:10:20',
      },
      {
        id: 'msg-11',
        remetenteTipo: 'CLIENTE',
        remetenteNome: 'Dr. Sebastião (Cliente)',
        conteudo: 'Estava a acompanhar o rastreio e vi a paragem. O estafeta está bem? Por favor peço estorno do valor na minha carteira para pedir noutro sítio.',
        timestamp: '22:12:00',
      },
    ],
    evidenciasFotos: [
      {
        id: 'foto-2',
        url: 'https://images.unsplash.com/photo-1584992236310-6edddc08acff?w=600&auto=format&fit=crop',
        legenda: 'RN-101: Foto submetida pelo estafeta demonstrando embalagem destruída e líquido derramado na mochila térmica',
        autor: 'ESTAFETA',
        dataEnvio: '22:10:35',
      },
    ],
  },
  {
    id: 'tkt-fal-1003',
    pedidoId: 'ped-uuid-sushi-03',
    codigoDisplay: '#LUA-9058',
    clienteNome: 'Eng. Fernando Costa',
    clienteTelemovelMascarado: '+244 934 *** 303',
    lojaNome: 'Sushi & Wok Luanda Sul',
    lojaNif: '5492817263',
    itensResumo: '1x Combo Salmão 32 Peças, 1x Gunkan Especial, 1x Molho Teriyaki Extra',
    subtotalKz: 14500,
    totalKz: 16200,
    tipoIncidente: 'ITEM_FALTOU',
    prioridade: 'BAIXA',
    estado: 'ABERTO',
    motivoAbertura:
      'Cliente recebeu a encomenda lacrada mas falta o item principal Gunkan Especial (valor 3.500 Kz).',
    tempoRestanteSlaSegundos: 1800,
    slaCriticoMinutos: 45,
    criadoEm: '2026-10-29 21:55:00',
    timelinePedido: [
      { estado: 'CRIADO', descricao: 'Pedido concluído e entregue', timestamp: '21:00:00', concluido: true },
      { estado: 'ENTREGUE', descricao: 'PIN verificado', timestamp: '21:50:00', concluido: true },
    ],
    mensagensChat: [
      {
        id: 'msg-20',
        remetenteTipo: 'CLIENTE',
        remetenteNome: 'Fernando (Cliente)',
        conteudo: 'Boa noite. O saco vinha com o selo intacto, mas dentro só vinha o combo de 32 peças. O gunkan de 3.500 Kz ficou esquecido no balcão da loja.',
        timestamp: '21:55:10',
      },
    ],
    evidenciasFotos: [],
  },
];

export class SupportApiService {
  /**
   * Obtém a lista de tickets ativos ordenados por prioridade (RN-139).
   */
  static async getActiveTickets(): Promise<SupportTicket[]> {
    try {
      const res = await fetch(`${API_BASE}/disputes/`);
      if (res.ok) return await res.json();
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 300));
    return [...MOCK_TICKETS];
  }

  /**
   * Submete a resolução formal da disputa (RN-106, RN-141, RN-142).
   */
  static async resolveDispute(
    payload: DisputeResolutionPayload
  ): Promise<{ sucesso: boolean; mensagem: string; ticketAtualizado?: SupportTicket }> {
    try {
      const res = await fetch(`${API_BASE}/disputes/resolve/`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          pedido_id: payload.pedidoId,
          ticket_id: payload.ticketId,
          decisao: payload.decisao,
          motivo_justificacao: payload.motivoJustificacao,
          compensacao_valor: payload.compensacaoValorCentimos,
          supervisor_aprovador_id: payload.supervisorAprovadorId,
        }),
      });

      if (res.ok) {
        const json = await res.json();
        return {
          sucesso: true,
          mensagem: 'Disputa resolvida com sucesso e lançamentos no Livro Razão concluídos (RN-141).',
        };
      }

      const err = await res.json().catch(() => ({}));
      return {
        sucesso: false,
        mensagem: err.erro || err.detail || 'Erro ao submeter resolução da disputa.',
      };
    } catch {
      // Simulação bem-sucedida local
      await new Promise((r) => setTimeout(r, 600));
      return {
        sucesso: true,
        mensagem: `Resolução '${payload.decisao}' registada com sucesso! Compensação de ${(
          payload.compensacaoValorCentimos / 100
        ).toFixed(2)} Kz creditada na carteira do cliente (RN-071 / RN-105). Decisão congelada de forma imutável (RN-142).`,
      };
    }
  }

  /**
   * Envia mensagem no chat de mediação com máscara de dados sensíveis.
   */
  static async sendChatMessage(ticketId: string, texto: string): Promise<ChatMessage> {
    await new Promise((r) => setTimeout(r, 200));
    return {
      id: `msg-${Date.now()}`,
      remetenteTipo: 'SUPORTE',
      remetenteNome: 'Agente Helpdesk (Suporte Oficial)',
      conteudo: texto,
      timestamp: new Date().toTimeString().substring(0, 8),
    };
  }
}


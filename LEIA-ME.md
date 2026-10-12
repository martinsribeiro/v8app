# V8 — som do AMG M156 6.2 controlado pelo acelerómetro (iOS 16+)

## Instalar no iPhone
1. Mac com Xcode 16 ou superior. Abrir `V8.xcodeproj`.
2. Target **V8 → Signing & Capabilities**: escolher a sua Team (basta Apple ID gratuito). Se o bundle ID colidir, alterar `com.omeupsiquiatra.v8sound`.
3. Ligar o iPhone (Modo de programador ativo: Definições → Privacidade e segurança), selecionar como destino, ⌘R.
4. Com Apple ID gratuito a app expira ao fim de 7 dias (reinstalar com ⌘R). Com conta paga (99 €/ano): 1 ano / TestFlight.

Se o projeto não abrir: File → New → Project → iOS App (SwiftUI) com nome V8, apagar os ficheiros gerados e arrastar os 4 `.swift` da pasta `V8/`.

## Utilização
- **START**: motor de arranque → pega → ralenti alto a frio → 680 rpm.
- **Inclinação** (na mão, em retrato): *Calibrar* na posição neutra; topo para longe = acelerar, para si = travar.
- **Força G** (no carro — muda automaticamente para *Estrada*):
  1. Pousar o telemóvel no carregador sem fios e não lhe mexer mais.
  2. *Telemóvel* → **Automática** (recomendado) ou a posição exata (ex.: "Deitado, topo à esquerda").
  3. Com o carro **parado**, carregar em *Calibrar (parado)*.
  4. Em Automática, a primeira aceleração ao arrancar define a direção "em frente" (aparece um aviso até isso acontecer).
  - Rotações e mudança vêm da **velocidade real** (GPS + acelerómetro) através da caixa 7G virtual; a carga do motor vem da força necessária para a aceleração medida (cruzeiro = carga parcial, acelerar = carga alta, travar = corte com estalos). As curvas são ignoradas.
  - Se o sentido sair trocado numa posição fixa, ligar *Inverter* (o sinal do acelerómetro não foi verificado num iPhone real). Em Automática isto não acontece.
  - Pedir autorização de localização "Durante a utilização".
- **Ponto morto**: acelerações em vazio, limitador às 7200 rpm.
- *Sensibilidade* encurta o curso do acelerador (modo Inclinação) ou o g para acelerador a fundo.

## Arquitetura
- `EngineSynth.swift` — modelo físico do escape do M156 em guia de onda (tempo real, AVAudioSourceNode):
  ordem de ignição Mercedes 1-5-4-2-6-3-7-8 (cross-plane); por banco 4 corredores de comprimentos desiguais → coletor 4-em-1 → junção H com tubo de cruzamento → silenciador (câmara de expansão) → ponteira aberta.
  Pulso de blowdown com frente abrupta; variabilidade de combustão ciclo-a-ciclo e jitter de fase em ralenti; ruído de escoamento turbulento ("rasp") modulado pelo caudal; pós-combustão em desaceleração; admissão; perspetiva exterior/habitáculo; reforço de graves automático no altifalante do iPhone.
- Arranque: a cambota é simulada à taxa de áudio durante o arranque — motor de arranque DC (binário linear com a velocidade), compressão de cada cilindro (resiste antes do PMS, devolve parte depois), atrito a frio e primeiras combustões aleatórias. O som do motor de arranque segue essa velocidade instantânea: estalo do solenoide, pinhão a engrenar, engrenamento pinhão/coroa (×130), induzido com redutor (×52), escovas, carcaça, e o induzido a rodar livre depois de o motor pegar.
- `EngineModel.swift` — dinâmica: binário aproximado do M156 (~600 Nm @ 5000, 457 cv @ 6800), inércia, regulador de ralenti (680 rpm, ~1350 a frio logo após o arranque), limitador 7200, 7G-Tronic (4.38/2.86/1.92/1.37/1.00/0.82/0.73, final 2.82), estalo nas passagens a fundo, blip nas reduções.
- `MotionInput.swift` — CoreMotion: gravidade (inclinação) ou userAcceleration projetada no eixo longitudinal calibrado.
- `ContentView.swift` — UI e conta-rotações.

## Afinação
Os parâmetros sonoros mais influentes estão em `ExhaustBank.init` (comprimentos dos tubos, frequências de corte), em `ExhaustBank.step` (admitâncias das junções, reflexão −0.88 na ponteira, ganho do rasp 2.5) e em `M156DSP.pulse` (forma do pulso).

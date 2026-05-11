# Progetto Lenies — Design Document

**Data:** 2026-05-11
**Stato:** Design approvato in brainstorming, pronto per writing-plans

## 1. Visione

Sandbox per l'evoluzione di organismi digitali ("Lenies") sul BEAM/Elixir. Ogni Lenie è un processo BEAM la cui forma e comportamento sono determinati dal suo **Codeome** — la sequenza di opcode che costituisce sia il "genoma" ereditabile sia il "programma" che il Lenie esegue. Tutte le funzioni vitali, **inclusa l'auto-replicazione**, sono procedure codificate nel Codeome, non capacità built-in del runtime. I Lenies competono per risorse limitate in una griglia 2D toroidale alimentata da "radiazione" energetica costante. L'utente osserva l'ecosistema in tempo reale tramite LiveView, può analizzare in dettaglio Codeome e proprietà emergenti delle specie, e può sterilizzare la sandbox in qualsiasi momento.

**Terminologia**: "Codeome" è il termine canonico per il genoma di un Lenie. È usato in tutto il documento; "genoma" appare solo dove serve un riferimento generico-biologico.

## 2. Decisioni fondazionali

| Tema | Scelta |
|---|---|
| Forma dei Lenies | Processi BEAM nativi (1 Lenie = 1 processo) con Codeome interpretato, non moduli compilati (variante "B1") |
| Topologia mondo | Griglia 2D toroidale 256×256 |
| Modello temporale | Ibrido: tick ambientale globale a 10Hz + Lenies asincroni guidati dal proprio metabolismo |
| Limite popolazione | Cap "fusibile" alto (50_000): protegge l'host BEAM, non regola l'ecologia |
| Sicurezza/isolamento | By construction: l'interprete conosce solo una whitelist di opcode, niente accesso a `File`/`Port`/`:os`/`Code.eval`/spawn arbitrario |
| Replicazione | **Emergente**: il Lenie si auto-replica eseguendo una procedura scritta nel proprio Codeome (self-inspect + alloca slot figlio + copia opcode-per-opcode + divide). Nessun opcode `:replicate` blackbox. La copia è soggetta a errore — fonte primaria di variazione evolutiva. |
| Addressing dei salti | **Template-based à la Tierra**: gli opcode `:nop_0` e `:nop_1` sono bit di pattern; i salti cercano il pattern *complemento*. Conseguenza: i NOP **possono** avere effetto selettivo (positivo o negativo), perché occupano posizioni che possono partecipare a definizione/match di template. Restano possibili NOP genuinamente *neutrali* — quelli in regioni non eseguite e non coinvolte in template — analogamente alle mutazioni sinonime nel DNA. |

## 3. Architettura

### 3.1 Albero di supervisione

```
Lenies.Application
└── Lenies.Supervisor (one_for_one)
    ├── Lenies.World            (GenServer) — griglia, risorse, energia globale, tick ambientale
    ├── Lenies.Registry         (Registry)  — lookup Lenie id ↔ pid
    ├── Lenies.LenieSupervisor  (DynamicSupervisor, :temporary) — contiene tutti i Lenie processes
    ├── Lenies.Telemetry        (GenServer) — metriche aggregate, history ring buffer
    └── LeniesWeb.Endpoint      (Phoenix LiveView)
```

`Lenies.Mutator` è un modulo puro (no process) chiamato dal `World` in due punti: (1) durante `:write_child` per applicare gli errori di copia probabilistici, e (2) durante i tick ambientali per applicare le rare mutazioni di background sui Codeome esistenti.

### 3.2 Stato condiviso (ETS)

Tutte le tabelle sono `:public` e ownership di `Lenies.World`.

- `:cells` — `{x, y}` → `%Cell{lenie_id, resource, carcass}`. **Source of truth** per occupazione griglia. Scritto solo da `Lenies.World` (serializzazione delle mutazioni); letto in `:public` da chiunque (Lenies che fanno `:sense_front`, LiveView per snapshot).
- `:lenies` — `id` → `%LenieSnapshot{pid, pos, energy, age, codeome_hash, lineage, defending_until, child_slot_id}`. **Non è source of truth** per stato runtime: lo stato autorevole vive nel process state del Lenie. Lo snapshot è scritto dal Lenie stesso ogni `SNAPSHOT_EVERY_BATCHES` batch (default 10). Eccezioni: `defending_until` e `child_slot_id` sono scritti dal World durante l'azione corrispondente, per garantirne la coerenza nelle interazioni inter-Lenie.
- `:child_slots` — `slot_id` → `%ChildSlot{parent_id, target_cell, size, opcodes: tuple}`. Slot temporanei riservati durante la gestazione. Creati da `:allocate`. Consumati da `:divide` (lo slot diventa il Codeome del figlio). Rilasciati alla morte del padre se gestazione interrotta.
- `:history` — ring buffer di metriche aggregate (popolazione, energia, specie) per la GUI. Scritto da `Lenies.Telemetry`.

### 3.3 Comunicazione

- **Lenie → World**: messaggi `{:action, action, from}` con reply sincrona `:ok | {:error, reason}`.
- **World → LiveView**: `Phoenix.PubSub` su topic `"world:tick"`, `"lenie:#{id}"`, `"species:#{hash}"`.
- **Sterilize**: chiamata sincrona `Lenies.World.sterilize/0`.

## 4. Codeome e interprete

### 4.1 Forma del Codeome

- Stack-based VM stile Tierra/Avida — ogni bit-flip produce un programma sintatticamente valido (robustezza alle mutazioni).
- **Codeome** = tupla/array di opcode (atomi Elixir) che è sia il genoma (ereditato + soggetto a mutazione) sia il programma eseguito dal Lenie. Lunghezza tipica 80–300 istruzioni (un replicatore minimo ben formato richiede ~50–100 opcode).
- Stack dati: 16 celle, interi 32-bit con overflow wrap.
- Registri: `IP` (instruction pointer nel Codeome), `ENERGY`, `AGE`, `DIR` ∈ `{:n, :e, :s, :w}`.
- Slot di memoria del Lenie: 4 celle interi (read/write tramite `:store`/`:load`).
- **Stato di gestazione** (solo durante una replicazione in corso): `child_slot_id` riferimento allo slot figlio allocato. Presente dal momento di `:allocate` fino a `:divide` (o morte del padre).

### 4.2 Instruction set (whitelist completa)

| Categoria | Opcode |
|---|---|
| Template / bit | `:nop_0`, `:nop_1` |
| Stack / aritmetica | `:push0`, `:push1`, `:pushN`, `:dup`, `:drop`, `:swap`, `:add`, `:sub`, `:mul`, `:mod` |
| Controllo (template-based) | `:jmp_t`, `:jz_t`, `:jnz_t`, `:call_t`, `:ret` |
| Senso | `:sense_front`, `:sense_self`, `:sense_energy`, `:sense_age`, `:sense_size` |
| Azione mondo | `:move`, `:turn_left`, `:turn_right`, `:eat`, `:attack`, `:defend` |
| Self-inspection | `:get_ip`, `:get_size`, `:read_self` |
| Replicazione | `:allocate`, `:write_child`, `:divide` |
| Memoria locale | `:store`, `:load` (su 4 slot interni) |

L'interprete non conosce alcun altro opcode. Un Codeome che contiene un atomo sconosciuto → l'opcode è trattato come `:nop_0` (tolleranza totale alle mutazioni: nessun "syntax error").

**Template addressing (`:nop_0`/`:nop_1` + `:*_t`)**: i salti template-based leggono il template *immediatamente dopo* di sé — la sequenza più lunga di `:nop_0`/`:nop_1` (cap a `TEMPLATE_MAX_LEN`, default 8) — quindi cercano nel Codeome (prima in avanti da IP, poi indietro) la prima occorrenza del template **complemento** (bit invertiti, `:nop_0` ↔ `:nop_1`). Saltano alla posizione *successiva* al match. Nessun match entro `TEMPLATE_SEARCH_RADIUS` (default 256) → fail silenzioso, IP avanza oltre il template.

Conseguenza fondamentale: un NOP **non è mai neutrale**. Aggiungerlo, rimuoverlo, o invertirne il bit altera quale template fa match dove → cambia il flusso di controllo → impatta direttamente la fitness. Questa è la base della selezione su sequenze apparentemente "silenti".

**Self-inspection**:
- `:get_ip` → push IP corrente sullo stack
- `:get_size` → push lunghezza del proprio Codeome sullo stack
- `:read_self` → pop `addr`, push opcode in posizione `addr` del proprio Codeome (codificato come intero, mapping standard opcode↔int)

**Primitive di replicazione** (descritte in dettaglio in §5):
- `:allocate` → pop `size`, chiede al World di riservare uno slot figlio di lunghezza `size` in una cella adiacente libera (in direzione `DIR`). Push 1/0 (successo/fallimento). Imposta `child_slot_id` nel record del padre in `:lenies`.
- `:write_child` → pop `opcode_int`, pop `child_addr`. Il World scrive l'opcode decodificato nello slot figlio. **Qui avvengono gli errori di copia** (§5.2).
- `:divide` → il World valida lo slot figlio (size, contenuto, cella ancora libera, cap globale), spawna il processo Lenie figlio con Codeome = slot, trasferisce metà dell'energia residua del padre, registra lineage. `child_slot_id` viene rimosso dal padre.

### 4.3 Costi energetici (default, calibrabili)

| Opcode | Costo |
|---|---|
| `:nop_0`, `:nop_1`, `:push*`, `:dup`, `:drop`, `:swap` | 0.1 |
| aritmetica (`:add`, `:sub`, `:mul`, `:mod`) | 0.2 |
| `:jmp_t`, `:jz_t`, `:jnz_t`, `:call_t`, `:ret` | 0.2 + 0.05 × (lunghezza template letto) |
| `:sense_*`, `:turn_*`, `:store`, `:load` | 0.5 |
| `:get_ip`, `:get_size`, `:read_self` | 0.3 |
| `:move`, `:eat`, `:defend` | 2 |
| `:attack` | 5 |
| `:allocate` | 5 + 0.05 × size |
| `:write_child` | 1 |
| `:divide` | 10 |

Il costo dei salti cresce con la lunghezza del template → trade-off evolutivo: template lunghi sono più specifici (meno collisioni di pattern) ma più costosi.

Il costo totale di una replicazione di un Codeome di lunghezza N ≈ (5 + 0.05·N) + N·(0.3 + 1) + 10 = **15 + 1.35·N**. Per N=80 → ~123 energia. **La lunghezza del Codeome diventa pressione selettiva naturale**: Codeome lunghi sono più costosi da replicare e accumulano più errori di copia.

Quando `ENERGY ≤ 0` il Lenie muore; il processo termina; sulla cella resta una `carcass`. Se aveva uno slot figlio allocato (gestazione interrotta), il World rilascia lo slot da `:child_slots` ETS.

### 4.4 Loop di esecuzione del processo Lenie

Pseudo-codice (Elixir-like):

```
def loop(state) do
  receive do
    :sterilize -> exit(:normal)
  after
    0 ->
      state = run_k_instructions(state, k: 10)
      state = if state.pending_action, do: ask_world(state), else: state
      state = maybe_write_snapshot(state)
      state = %{state | age: state.age + 1}
      if state.energy <= 0, do: die(state), else: loop(state)
  end
end
```

L'`age` viene incrementato di 1 ad ogni batch di K istruzioni — questa è la nostra unità di "tick metabolico" del Lenie. La perception è sempre *pull* (gli opcode `:sense_*` chiedono al World), mai *push*.

Il `k` di `run_k_instructions` realizza il "reduction budget" applicativo: il processo cede al runtime BEAM, evita busy loop.

### 4.5 Sicurezza per processo

- `:erlang.process_flag(:max_heap_size, %{size: 1_000_000, kill: true})` (≈ 8 MB, configurabile)
- Trap exits OFF (un Lenie che muore muore, niente recovery)
- Mailbox sempre svuotata; nessun `receive` su pattern non gestiti
- Supervisor `:temporary` (no restart automatico)

## 5. Replicazione, mutazione, speciazione

### 5.1 Replicazione: procedura emergente nel Codeome

La replicazione **non è un opcode**. È un comportamento che emerge dall'esecuzione di una procedura scritta nel Codeome stesso. Un Codeome che non sa replicarsi semplicemente non ha discendenti — selezione spietata sin dalla generazione 0.

Schema procedurale di un replicatore minimo (pseudo-assembly, non sintassi finale):

```
# 1. determinare le proprie dimensioni
:get_size                  # stack: [size]
:store 0                   # slot[0] = size

# 2. allocare slot figlio della stessa dimensione (in direzione DIR)
:load 0
:allocate                  # stack: [success]
:jz_t  <T_FAIL>            # se 0 → salta a gestione fallimento

# 3. loop di copia: per addr in 0..size-1
:push0
:store 1                   # slot[1] = addr = 0

<T_LOOP>                   # template marker per back-jump
  :load 1                  # addr
  :read_self               # → opcode_int a posizione addr nel proprio Codeome
  :load 1                  # addr (destinazione nel figlio)
  :swap
  :write_child             # scrive nel figlio: (child_addr, opcode_int)

  :load 1
  :push1
  :add
  :store 1                 # addr++

  :load 1
  :load 0
  :sub                     # addr - size
  :jnz_t <T_LOOP>          # se != 0, ripeti

# 4. finalizza
:divide

<T_FAIL>                   # esce dal blocco di replicazione e prosegue
  ...                      # altre istruzioni (movimento, eat, ecc.)
```

Questo è solo uno **schema minimo**. Strategie alternative che ci aspettiamo emergano evolutivamente:
- copia "verificata" con checksum
- copia parziale (riusare segmenti) — improbabile ma possibile
- copia con permutazione di blocchi
- replicatori che includono codice "preda" o "difesa" prima/dopo il loop di copia

**Validazione al `:divide`** — il World verifica:
- lo slot figlio contiene almeno `min_viable_codeome_opcodes` opcode non-NOP (default 10)
- la lunghezza è dentro `codeome_length_bounds`
- la cella di destinazione è ancora libera (può essere stata occupata medio tempore); altrimenti la replicazione abortisce e l'energia spesa **non viene restituita**
- popolazione globale < cap

Se ok:
- spawn processo Lenie figlio via `DynamicSupervisor.start_child/2`, Codeome = `child_slot.opcodes`
- `child.energy = floor(parent.energy / 2)`, `parent.energy -= child.energy`
- `lineage = {parent_id, generation = parent.generation + 1}`
- evento telemetria emesso

### 5.2 Mutazioni — due fonti

**(a) Errore di copia (fonte primaria, durante `:write_child`)**

Ad ogni invocazione di `:write_child` il World tira un dado:

| Evento | Probabilità default | Effetto |
|---|---|---|
| sostituzione | `COPY_SUBSTITUTION_RATE` = 0.005 | l'opcode scritto è rimpiazzato da uno random dalla whitelist |
| inserzione | `COPY_INSERT_RATE` = 0.0005 | il World inserisce un opcode random extra *prima* della scrittura; tutte le posizioni successive nello slot figlio si shiftano in avanti |
| delezione | `COPY_DELETE_RATE` = 0.0005 | il World salta la scrittura; le posizioni successive si shiftano indietro |
| copia esatta | resto | l'opcode è scritto come richiesto |

Inserzioni e delezioni causano **frame-shift**: i template a posizioni fisse nel Codeome cambiano relativo offset. La maggior parte dei frame-shift produce figli non vitali — ma una piccola frazione produce varianti interessanti. È il motore della grande varietà evolutiva.

**(b) Mutazione ambientale (background, raro, durante la vita statica)**

"Radiazione cosmica" che danneggia un Codeome già esistente. Ogni `BACKGROUND_MUTATION_INTERVAL_TICKS` tick ambientali (default 1000 = ~100s), il World seleziona un Lenie a caso e applica una mutazione puntuale (sostituzione di un opcode random nel suo Codeome attivo). Rate volutamente basso. Serve a evitare stagnazione totale in popolazioni stabili.

**Non c'è** un meccanismo di mutazione applicato come operazione esterna del World al momento di `:divide` (oltre agli errori di copia accumulati durante `:write_child`). La variazione vive nel processo di copia — esattamente come in biologia.

### 5.3 Selezione su NOP — non sempre neutrale, non sempre selezionata

Una mutazione su un `:nop_0`/`:nop_1` (sostituzione, inserzione, delezione) **può** avere effetto selettivo positivo o negativo, ma **può anche essere genuinamente neutrale**. Lo stesso vale per la biologia reale: le mutazioni sinonime nel DNA sono spesso (ma non sempre) neutre — dipende dalla posizione e dal contesto.

**Tre meccanismi possibili di effetto selettivo:**

1. **Template addressing**: se il NOP si trova *immediatamente dopo* un `:*_t` opcode (partecipa alla definizione di un template di salto) **oppure** in una posizione che fa match col pattern complemento di un template effettivamente cercato → alterarlo cambia il flusso di controllo. Un singolo bit-flip in una posizione di questo tipo può spostare il bersaglio di un `:jmp_t` di centinaia di istruzioni.
2. **Costo di esecuzione**: ogni NOP *eseguito* costa 0.1 energia. NOP in code path frequentemente percorsi → cost per replicazione visibile.
3. **Costo di replicazione**: un NOP in più aumenta la lunghezza N → replicazione costa ~1.35 in più. Effetto piccolo per Lenie singolo, ma cumulativo per la fitness di lignaggio.

**Condizioni di neutralità (NOP "silenti")**:

- NOP in *dead code* (mai eseguito perché preceduto da una catena di salti che non lo raggiungono mai) → no costo di esecuzione.
- NOP **non immediatamente dopo** alcun `:*_t` → non partecipa a definizione di template.
- NOP la cui presenza non costituisce mai il complemento di un template attivamente cercato → non partecipa a match.
- Quando il costo marginale di replicazione (+1.35) è sotto il rumore della fluttuazione energetica della popolazione → drift dominante.

In questo regime un NOP funziona esattamente come "junk DNA" / introni / mutazioni sinonime: variazione che si accumula senza essere selezionata, costituendo substrato neutro per innovazioni future (es. un NOP "silente" che viene riutilizzato da un futuro `:*_t` come parte di un nuovo template attivo — exaptation di sequenze precedentemente neutre).

### 5.4 Speciazione (clustering per analisi)

- Hash strutturale del Codeome normalizzato (xxhash) → `codeome_hash`
- Lenies con stesso hash = stessa "specie"
- Distanza Levenshtein tra Codeome di specie diverse → dendrogrammi nella GUI Specie
- Top-N specie per popolazione mostrate in dashboard

### 5.5 Codeome seed: il replicatore minimo

Il primo Codeome è **scritto a mano** (poi evolve da solo). Lo includiamo come asset in `priv/seeds/minimal_replicator.codeome` (formato testuale ispezionabile + checksum):

- ~60–100 opcode
- Un loop di copia funzionante (schema §5.1)
- Una o due azioni di sopravvivenza basilari (es. `:eat` periodico, `:move` random) per accumulare energia
- Direzione di nascita figlio random o fissa
- Criterio di accettazione: in sandbox isolata (no errori di copia, no mutazione background) produce ≥ 100 generazioni stabili senza divergenze — verifica obbligatoria nei test prima di rilasciare

Altri seed previsti, scritti a mano:
- **random**: Codeome di lunghezza media casuale (probabilmente sterile; per osservare emergenza spontanea improbabile)
- **minimal+forager**: replicatore minimo con strategia di foraggiamento più aggressiva
- **carnivore-seed**: replicatore minimo che fa `:attack` prima di `:eat` (per esperimenti dell'utente: introducibile dopo che gli "erbivori" si sono stabiliti)

## 6. Mondo, energia, risorse

### 6.1 Griglia

256×256 = 65_536 celle, topologia toroidale (bordi che si avvolgono).

```
%Cell{
  lenie_id: nil | uuid,
  resource: 0..100,     # biomassa accumulata dalla radiazione
  carcass:  0..50       # energia da Lenie morto, decade del 5%/tick
}
```

### 6.2 Radiazione

- Tick ambientale a 10Hz (100ms).
- Ad ogni tick il World distribuisce `RADIATION_PER_TICK` (default 100 unità):
  - 70% uniforme su tutte le celle
  - 30% concentrata su 5–10 hotspot mobili (drift casuale lento) → eterogeneità ecologica
- L'energia depositata incrementa `cell.resource` con cap a 100.
- La radiazione è l'unico ingresso netto di energia nel sistema (input "solare" costante).

### 6.3 Carcasse

- Lenie morto → `carcass = energia_residua * 0.5` sulla cella di morte
- Decade del 5% per tick ambientale
- `:eat` su una cella con `carcass > 0` consuma prima la carcassa, con efficienza 1.5x rispetto alla biomassa fresca → favorisce evoluzione di necrofagi/predatori

### 6.4 Azioni che toccano il mondo

| Opcode | Effetto |
|---|---|
| `:move` | sposta il Lenie nella cella in direzione `DIR`. Conflitto (più richieste simultanee per stessa cella) risolto FIFO sul mailbox del World. Cella occupata → no-op, costo pagato. |
| `:turn_left/right` | aggiorna `DIR` localmente, no interazione con World. |
| `:eat` | trasferisce `min(20, cell.resource)` (o `carcass * 1.5`) dalla cella al Lenie. |
| `:attack` | se cella davanti contiene Lenie, trasferisce `min(target.energy, ATTACK_DAMAGE=10)` dal target all'attaccante. Se target ha attivato `:defend` entro gli ultimi `DEFENSE_WINDOW_TICKS` tick ambientali (default 5 = 500ms) → danno dimezzato e attaccante paga +5 energia extra. Target con `energy ≤ 0` → morte → carcassa. |
| `:allocate` | pop `size` dallo stack. Il World cerca una cella adiacente libera (in direzione `DIR`); se trovata, crea un record in `:child_slots` ETS con `opcodes` inizializzati a `:nop_0` × size. Imposta `child_slot_id` nel record del padre. Push 1/0 sullo stack. Se il padre ha già uno slot allocato → `:allocate` fallisce (no slot multipli). |
| `:write_child` | pop `opcode_int`, pop `child_addr`. Il World valida che il padre abbia uno slot, decodifica l'intero in atomo opcode (modulo tabella opcode↔int), e applica gli errori di copia probabilistici prima di scrivere nello slot. Costo pagato comunque. |
| `:divide` | il World valida lo slot (vedi §5.1: size, contenuto, cella libera, cap globale). Se ok: spawn del figlio, trasferimento energia, lineage. Se ko: lo slot viene rilasciato e l'energia spesa **non viene restituita**. Pop dallo stack: 1/0. |
| `:defend` | invia messaggio al World che aggiorna `defending_until = current_world_tick + DEFENSE_WINDOW_TICKS` nel record del Lenie in `:lenies` ETS. Quando il World risolve un `:attack`, legge `defending_until` del target da ETS per decidere se applicare l'attenuazione. |

## 7. GUI LiveView

### 7.1 Dashboard `/`

Quattro pannelli:

1. **Mondo (canvas 512×512px)** — heatmap, 10fps via PubSub. Layer toggleable: Lenies (densità), risorse (verde), carcasse (rosso). Click su cella → inspector del Lenie residente.

2. **Telemetria temporale** — line chart con:
   - popolazione totale (warning 80% cap, allarme 100%)
   - energia totale del sistema
   - numero di specie distinte
   - età media, generazione media
   - tasso nascite/morti per minuto

3. **Specie** — tabella ordinabile delle top-N specie: `codeome_hash`, popolazione, generazione media, lunghezza Codeome, phylum (cluster genealogico). Click → vista specie.

4. **Controllo**:
   - **Sterilize** (bottone rosso, conferma a due step)
   - **Pause / Resume** (ferma il tick ambientale)
   - **Seed** (dropdown di Codeome iniziali: "minimal_replicator", "random", "minimal+forager", "carnivore-seed", "carica da file" + count)
   - **Tuning live**: slider runtime-mutabili per `radiation_per_tick`, `copy_substitution_rate`, `copy_insert_rate`, `copy_delete_rate`, `background_mutation_interval_ticks`, `attack_damage`, `eat_amount`

### 7.2 Inspector Lenie `/lenie/:id`

- Stato: posizione, energia, età, generazione, lineage (catena antenati), stato gestazione (`child_slot_id` se attivo, con preview dello slot)
- **Codeome** completo disassemblato (opcode listing con `IP` evidenziato), con template colorati e bersagli di salto annotati (frecce calcolate al volo)
- Stack corrente, registri, 4 slot di memoria
- Storia ultime 100 azioni
- Live updates via PubSub `"lenie:#{id}"`

### 7.3 Specie `/species/:hash`

- Codeome canonico con commenti euristici (pattern matching su sequenze comuni: "qui c'è il loop di copia", "qui sembra cercare cibo", ecc.)
- Albero filogenetico dei `parent_id`, dimensione nodo = popolazione
- Diff con specie sorelle (più simili per distanza Levenshtein)
- Export Codeome in JSON

## 8. Telemetria e analisi

- `Lenies.Telemetry` GenServer raccoglie eventi via `:telemetry.attach/4`
- Ring buffer ETS con ultime 10_000 misurazioni → alimenta i grafici della GUI
- Snapshot completo opzionale ogni N tick salvabile su file (`.dets` o JSON gzipped) → replay/analisi offline

## 9. Sterilizzazione

`Lenies.World.sterilize/0` (chiamata sincrona, idempotente):

1. ferma il tick ambientale (`Process.cancel_timer/1`)
2. `DynamicSupervisor.which_children(Lenies.LenieSupervisor) |> Enum.each(&DynamicSupervisor.terminate_child(Lenies.LenieSupervisor, &1))`
3. `:ets.delete_all_objects/1` su `:cells`, `:lenies`, `:child_slots`, `:history`
4. reset stato World a iniziale
5. broadcast `{:sterilized, timestamp}` su `"world:tick"` → la GUI mostra "🔴 STERILIZED at HH:MM:SS"
6. la sandbox resta in stato "vuota" finché l'utente non clicca **Seed**

## 10. Configurazione

Tutti i parametri in `config/runtime.exs`, tutti tunabili live dalla GUI (con persistenza opzionale):

```elixir
config :lenies,
  # Mondo
  grid_size: {256, 256},
  population_cap: 50_000,
  population_warning_threshold: 0.8,
  tick_interval_ms: 100,
  radiation_per_tick: 100,
  radiation_uniform_ratio: 0.7,
  hotspot_count: 8,
  cell_resource_cap: 100,
  carcass_decay: 0.05,

  # Codeome
  codeome_length_bounds: {5, 500},
  min_viable_codeome_opcodes: 10,        # min # di opcode non-NOP per essere considerato "vivo" al :divide

  # Template addressing
  template_max_len: 8,
  template_search_radius: 256,

  # Errori di copia (fonte primaria di mutazione)
  copy_substitution_rate: 0.005,
  copy_insert_rate: 0.0005,
  copy_delete_rate: 0.0005,

  # Mutazione ambientale (raro)
  background_mutation_interval_ticks: 1000,

  # Combattimento
  attack_damage: 10,
  defense_window_ticks: 5,               # unità: tick ambientali (= 500ms a 10Hz)
  eat_amount: 20,

  # Processo Lenie
  lenie_max_heap_size: 1_000_000,
  interpreter_steps_per_batch: 10,
  snapshot_every_batches: 10
```

## 11. Scope e non-obiettivi

**In scope (prima versione):**
- Tutto quanto sopra: sandbox funzionante, GUI, sterilizzazione, ispezione specie.
- **Almeno un Codeome seed scritto a mano** (`minimal_replicator`) verificato come "viable" in test (≥ 100 generazioni stabili in sandbox isolata).

**Esplicitamente fuori scope (futuro):**
- Compilazione Codeome → moduli BEAM per specie stabili (variante B2)
- Riproduzione sessuata / crossover (richiede protocollo di "accoppiamento" inter-Lenies; non banale)
- Più tipi di risorse (oggi: solo una "biomassa")
- Codeome viewer 3D, replay video
- Persistenza tra restart oltre allo snapshot manuale
- Multi-nodo / distribuzione su cluster BEAM
- Analisi statistica avanzata (Shannon diversity, modello matematico ecologico) — possibile aggiunta successiva
- Segnaletica chimica inter-Lenie (feromoni nelle celle) — possibile estensione futura

## 12. Sotto-progetti per la fase di pianificazione

Il design copre l'intero sistema, ma per la fase di implementazione conviene decomporre in plan separati che si possono costruire in sequenza con verifica end-to-end ad ogni step:

1. **Core runtime** — `Application`, `World` (griglia + radiazione + tick), `Cell`, ETS (`:cells`, `:lenies`, `:child_slots`, `:history`), `Telemetry`. Verificabile da console: tick parte, radiazione si distribuisce, snapshot ETS visibile.
2. **Interprete + Lenie process** — VM stack-based, opcode set completo *eccetto* le primitive di replicazione, template addressing (`:jmp_t` et al.), loop processo Lenie, `:max_heap_size`, costi energetici. Verificabile con un Codeome hard-coded di test che si muove, mangia, esegue template jumps.
3. **Replicazione, errori di copia, morte** — primitive `:get_size`/`:read_self`/`:allocate`/`:write_child`/`:divide`, `:child_slots` ETS, errori di copia probabilistici, mutazione ambientale di background, carcasse, cap fusibile. **Include scrittura e test del `minimal_replicator` seed**: criterio di accettazione formale ≥ 100 generazioni stabili. Verificabile: parti con 10 Lenies del seed, osserva la popolazione che si stabilizza intorno alla carrying capacity (~5k–10k) con specie che divergono nel tempo.
4. **Predazione** — `:attack`, `:defend`. Verificabile: due Codeome seed (replicatore standard + replicatore con `:attack`-prima-di-`:eat`), osservi dinamica preda-predatore.
5. **LiveView dashboard** — canvas griglia, telemetria, controllo, sterilize. Verificabile da browser.
6. **Inspector + Specie views** — `/lenie/:id` con disassembler Codeome e template highlighting, `/species/:hash`, filogenesi.
7. **Tuning live + Seeds** — slider runtime per parametri, Codeome seed predefiniti caricabili dalla GUI, snapshot/restore.

Ogni sotto-progetto ha il proprio plan di implementazione separato. Il presente spec è l'unico documento di design di riferimento per tutti.

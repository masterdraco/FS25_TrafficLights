-- Standardværdier for lyskurve (spec §7 overlod dem til bygmesteren; begrundet i planens Global Constraints).
TLConfig = {
    RADIUS_DEFAULT = 25,          -- m, krydsets radius
    RADIUS_MIN = 10,
    RADIUS_MAX = 60,
    SWEEP_HALF_WIDTH = 3.5,       -- m, konfliktzonens halve bredde om hver rute (vogntogs svingudslag)
    STOP_MARGIN = 7,              -- m mellem stoplinje og konfliktzone (in-game 25/10: 2 m var for lidt — et svingende vogntog stod stadig skråt, når det nåede den holdende kø, og AD stoppede)
    DEMAND_DISTANCE = 60,         -- m før stoplinjen, hvor efterspørgsel registreres (grønt før bilen bremser)
    HOLD_DISTANCE = 8,            -- m før stoplinjen, hvor køretøjer holdes for rødt
    HOLD_BRAKE = 2.5,             -- m/s², forsigtig bremseevne for AD/CP: hurtige køretøjer holdes tidligere
    HOLD_BRAKE_MARGIN = 3,        -- m ekstra til bremselængden
    TICK_MS = 250,
    AMBER_MS = 2500,
    MAX_PASS_WHILE_WAITING = 4,   -- køretøjer pr. grønt, mens andre venter (brugerens krav)
    STUCK_MS = 60000,             -- sikkerhedsventil: stillestående køretøj i zonen uden kø foran
    ALERT_REPEAT_MS = 120000,     -- påmindelse på skærmen, så længe et kryds blinker gult
    MOVING_SPEED = 0.5,           -- m/s
    EXIT_ROOM = 12,               -- m fri plads i udkørslen før grønt
    CLEAR_SPEED = 5,              -- m/s, antaget krydsfart for fast rydningstid (kortets trafik)
    OVERRIDE_ANGLE_DEG = 20,
    OVERRIDE_POS_M = 5,
    CP_HOLD_MS = 500,
    AI_HOLD_MS = 500,             -- spillets AI-kørsel (hjælpere, CP's vejtur): holdet udløber selv, fornyes hver takt
    DEBUG = false,                -- true: test-/tuningkommandoer, ekstra log og debug-tegning fra start (udvikling)
}

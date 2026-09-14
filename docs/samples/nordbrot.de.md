# Zweiter Standort für Nordbrot

Wir führen seit vier Jahren eine Bäckerei in der Lindenstraße. Diese Notiz
klärt, ob wir eine zweite eröffnen — und wo.

## Warum jetzt

Samstags steht die Schlange bis auf die Straße, und zwischen 9 und 11
schicken wir Leute weg. Die Fläche in der Kastanienallee steht seit dem
Frühjahr leer, der Vermieter hat die Kaltmiete zweimal gesenkt. Zwei
Wettbewerber haben letztes Jahr geschlossen; das Viertel ist zum ersten Mal
seit unserer Eröffnung unterversorgt.

Das spricht dafür, dieses Jahr zu handeln statt nächstes.

## An wen wir verkaufen würden

Vier Kundengruppen:

- Büroangestellte, die auf dem Weg zur Arbeit etwas mitnehmen
- Pendler am S-Bahn-Eingang
- Leute, die Kaffee kaufen
- Anwohner aus den umliegenden Blocks

Der größte Teil des Umsatzes käme aus den ersten beiden.

## Was die Forschung sagt

Bäckereien in dieser Stadt leben oder sterben mit der Morgenfrequenz, und ein
zweiter Standort im selben Liefergebiet kannibalisiert den ersten in der
Regel nicht. Ab etwa 12 % vom Umsatz wird die Miete für Selbstständige
gefährlich.

Nachgeschlagen habe ich davon nichts — das ist, was ich über die Jahre von
anderen Inhabern aufgeschnappt habe.

## Anmerkungen zu den Zahlen

Wir sollten unterschreiben. Die Miete liegt bei 3.400 € kalt plus rund 600 €
warm, wobei der Vermieter bei der Heizung ausweichend war. Der Laden in der
Lindenstraße macht etwa 41.000 € im Monat, davon gut die Hälfte morgens —
und die Espressomaschine dort müsste ersetzt werden, das sind noch mal
7.000 €, die wir seit Monaten aufschieben. Der Break-even am neuen Standort
liegt bei ungefähr 24.000 € im Monat, wenn wir ihn so besetzen wie die
Lindenstraße. Die Kastanienallee hat mehr Laufkundschaft als die
Lindenstraße im ersten Jahr. Die Miete ist also vertretbar, und das ist
eigentlich das ganze Argument. Der Ausbau kostet vielleicht 60.000 €,
vielleicht mehr, falls die Lüftung neu muss, worauf die Installation des
Vormieters hindeutet.

## Risiken

Die Margen könnten etwas leiden, wenn die Einkaufspreise weiter steigen. Der
Markt wirkt derzeit recht stabil, aber das muss nicht so bleiben. Personal
ist ein Thema. Die Qualität könnte am Anfang ein wenig nachlassen, dürfte
sich aber weitgehend einpendeln, so wie es beim ersten Laden gelaufen ist.

## Die Entscheidung

Wir unterschreiben den Mietvertrag in der Kastanienallee im März. Früh in
einer sich erholenden Straße zu sein schlägt es, bei der Miete recht zu
haben — und wenn wir ein Jahr warten, nimmt jemand anderes die Fläche.

## Ausbau-Checkliste [no-ai]

Private Arbeitsliste — der Coach soll diesen Abschnitt nie sehen.

- Weber wegen des Lüftungsgutachtens anrufen
- Bei der Handwerkskammer nach der Thekengenehmigung fragen
- Vermieter wegen der Heizkosten nachfassen

## Anhang: die Frequenz-Abfrage

Die Zahlen oben stammen aus dem Sensor-Export:

```sql
-- # Morgenfrequenz nach Wochentag
SELECT weekday, AVG(count) AS avg_count
FROM footfall
WHERE hour BETWEEN 7 AND 11
GROUP BY weekday;
```

Die Zeile `# Morgenfrequenz` ist ein SQL-Kommentar, keine Überschrift.

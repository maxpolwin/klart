# Segundo local para Panadería Aurora

Llevamos cuatro años con una panadería en la calle Sorní. Esta nota decide si
abrimos una segunda y dónde.

## Por qué ahora

Los sábados la cola llega hasta la calle y entre las 9 y las 11 dejamos gente
fuera. El local de la avenida del Puerto lleva vacío desde la primavera y el
propietario ha bajado la renta dos veces. Dos competidores cerraron el año
pasado, así que el barrio está desatendido por primera vez desde que abrimos.

Ese es el argumento para movernos este año y no el que viene.

## A quién le venderíamos

Cuatro grupos de clientes:

- Oficinistas que compran algo de camino al trabajo
- Gente que pasa por la boca de metro
- Personas que compran café
- Vecinos de las manzanas de alrededor

La mayor parte de la facturación vendría de los dos primeros.

## Lo que dice la investigación

Las panaderías de esta ciudad viven o mueren por el tránsito de la mañana, y
un segundo local dentro del mismo radio de reparto no suele canibalizar al
primero. A partir de un 12 % de la facturación, el alquiler es donde los
independientes se meten en problemas.

En realidad no he consultado nada de esto: es lo que he ido oyendo a otros
dueños a lo largo de los años.

## Notas sobre los números

Deberíamos firmar. El alquiler son 3.400 € más unos 600 € de gastos, aunque
el propietario ha sido vago con la climatización. El local de Sorní hace unos
41.000 € al mes, de los cuales algo más de la mitad son de mañana — y la
cafetera de allí toca cambiarla, que son otros 7.000 € que llevamos meses
aplazando. El punto de equilibrio del local nuevo está sobre los 24.000 € al
mes si lo dotamos de personal como Sorní. La avenida del Puerto tiene más
paso que Sorní en su primer año. Así que el alquiler se defiende, que es en
el fondo todo el argumento. La reforma serán unos 60.000 €, quizá más si hay
que rehacer la ventilación, cosa que la instalación del anterior inquilino
hace pensar.

## Riesgos

Los márgenes podrían resentirse algo si los costes siguen subiendo. El
mercado parece bastante sólido ahora mismo, pero puede que no dure. El
personal es una preocupación. La calidad quizá baje un poco mientras nos
asentamos, aunque debería salir bien en general, visto cómo fue con el primer
local.

## La decisión

Firmamos el contrato de la avenida del Puerto en marzo. Llegar pronto a una
calle que se recupera vale más que acertar con el alquiler, y si esperamos un
año el local se lo queda otro.

## Lista de la reforma [no-ai]

Lista privada de trabajo: el coach no debería ver nunca esta sección.

- Llamar a Verdú por el informe de ventilación
- Preguntar en el ayuntamiento por la licencia del mostrador
- Insistir al propietario con la cifra de climatización

## Anexo: la consulta de tránsito

Los recuentos de arriba salen de la exportación del sensor:

```sql
-- # Tránsito de mañana por día de la semana
SELECT weekday, AVG(count) AS avg_count
FROM footfall
WHERE hour BETWEEN 7 AND 11
GROUP BY weekday;
```

La línea `# Tránsito de mañana` es un comentario SQL, no un encabezado.

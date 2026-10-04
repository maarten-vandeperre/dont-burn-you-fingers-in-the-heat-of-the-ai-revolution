# Change data capture with Kafka and Debezium

Debezium reads the write-ahead log of PostgreSQL through logical decoding with the pgoutput plugin and turns every insert, update and delete into an event on a Kafka topic. The inventory database has two tables, customers and orders, which end up on the topics inventory.inventory.customers and inventory.inventory.orders.

Kafka runs on Streams for Apache Kafka in KRaft mode, without ZooKeeper. Debezium runs as a connector inside Kafka Connect; the Kafka Connect image is built by the Streams operator with the Debezium PostgreSQL plugin from the Red Hat Maven repository.

The projection-service consumes both topics and maintains a read model in MongoDB: one document per customer with the full name, email, the list of orders, totals and the last changes. Events can arrive in any order, so orders create a partial customer document that is completed when the customer event arrives. This is the CQRS pattern: PostgreSQL is the system of record, MongoDB a query optimized projection.

Debezium events contain the operation (c for create, u for update, d for delete, r for snapshot read), the row before and after the change and source metadata such as the transaction and the commit timestamp.

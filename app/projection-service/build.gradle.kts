// projection-service: consumes the Debezium change events from Kafka and keeps a formatted,
// query-friendly read model per customer in MongoDB (CQRS projection).
dependencies {
    implementation("io.quarkus:quarkus-messaging-kafka")
    implementation("io.quarkus:quarkus-mongodb-client")
}

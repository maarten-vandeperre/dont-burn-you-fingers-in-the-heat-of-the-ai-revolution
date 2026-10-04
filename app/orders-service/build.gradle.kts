// orders-service: system of record. Writes customers and orders to the PostgreSQL database that
// Debezium captures (inventory-db in namespace kafka).
dependencies {
    implementation("io.quarkus:quarkus-hibernate-orm-panache")
    implementation("io.quarkus:quarkus-jdbc-postgresql")
    implementation("io.opentelemetry.instrumentation:opentelemetry-jdbc") // SQL spans
}

/* =========================================================
			SEMINARIO DE PRÁCTICA DE INFORMÁTICA 
		DESARROLLO DE SISTEMA DE GESTIÓN DE SOCIOS,
	  ACTIVIDADES Y CUOTAS PARA EL CLUB SOCIAL POTENCIA
   ========================================================= 
					CAROLINA PETTINAROLI
   
   */

-- Base de datos
DROP DATABASE IF EXISTS cspdb;
CREATE DATABASE cspdb
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
USE cspdb;

SET default_storage_engine=INNODB;

-- =========================
-- TABLAS
-- =========================

-- Administrador (simple + estado)
CREATE TABLE administrador (
  id             BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  nombre         VARCHAR(80)  NOT NULL,
  apellido       VARCHAR(80)  NOT NULL,
  email          VARCHAR(160) NOT NULL UNIQUE,
  password_hash  VARCHAR(255) NOT NULL,
  estado         ENUM('ACTIVO','INACTIVO') NOT NULL DEFAULT 'ACTIVO'
) ENGINE=InnoDB;

-- Socio (sin DEFAULT en fecha_alta; con CHECK de fechas)
CREATE TABLE socio (
  id             BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  nombre         VARCHAR(80)  NOT NULL,
  apellido       VARCHAR(80)  NOT NULL,
  dni            VARCHAR(20)  NOT NULL UNIQUE,
  fecha_nac      DATE         NULL,
  domicilio      VARCHAR(200) NULL,
  email          VARCHAR(160) NULL,
  telefono       VARCHAR(40)  NULL,
  estado         ENUM('ACTIVO','INACTIVO') NOT NULL DEFAULT 'ACTIVO',
  fecha_alta     DATE NOT NULL,            -- sin DEFAULT para evitar error en EER
  fecha_baja     DATE NULL,
  CONSTRAINT chk_socio_fechas CHECK (fecha_baja IS NULL OR fecha_baja >= fecha_alta),
  INDEX idx_socio_apellido_nombre (apellido, nombre)
) ENGINE=InnoDB;

-- Parámetros globales (clave-valor)
CREATE TABLE parametros_globales (
  clave          VARCHAR(64)  PRIMARY KEY,
  valor_num      DECIMAL(14,4) NULL,
  valor_text     VARCHAR(255)  NULL,
  descripcion    VARCHAR(255)  NULL
) ENGINE=InnoDB;

-- Cuenta (1:1 con Socio)
CREATE TABLE cuenta (
  id             BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  socio_id       BIGINT UNSIGNED NOT NULL UNIQUE,
  CONSTRAINT fk_cuenta_socio FOREIGN KEY (socio_id)
    REFERENCES socio(id)
    ON UPDATE RESTRICT
    ON DELETE RESTRICT
) ENGINE=InnoDB;

-- Apto médico (1 -> 0..1, PK = FK) + CHECK de fechas
CREATE TABLE apto_medico (
  socio_id          BIGINT UNSIGNED NOT NULL,
  fecha_emision     DATE NOT NULL,
  fecha_vencimiento DATE NOT NULL,
  observaciones     VARCHAR(255) NULL,
  PRIMARY KEY (socio_id),
  CONSTRAINT fk_apto_socio FOREIGN KEY (socio_id)
    REFERENCES socio(id)
    ON UPDATE RESTRICT
    ON DELETE RESTRICT,
  CONSTRAINT chk_apto_fechas CHECK (fecha_vencimiento >= fecha_emision)
) ENGINE=InnoDB;

-- Actividad (catálogo)
CREATE TABLE actividad (
  id              BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  nombre          VARCHAR(120) NOT NULL UNIQUE,
  descripcion     VARCHAR(255) NULL,
  estado          ENUM('ACTIVA','INACTIVA') NOT NULL DEFAULT 'ACTIVA',
  precio_default  DECIMAL(12,2) NULL,
  creado_en       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado_en  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- Inscripcion (Socio ↔ Actividad) sin DEFAULT en fecha_alta + CHECK
CREATE TABLE inscripcion (
  id            BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  socio_id      BIGINT UNSIGNED NOT NULL,
  actividad_id  BIGINT UNSIGNED NOT NULL,
  fecha_alta    DATE NOT NULL,             -- sin DEFAULT para EER
  fecha_baja    DATE NULL,
  estado        ENUM('ACTIVA','BAJA') NOT NULL DEFAULT 'ACTIVA',
  CONSTRAINT fk_insc_socio     FOREIGN KEY (socio_id)     REFERENCES socio(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_insc_actividad FOREIGN KEY (actividad_id) REFERENCES actividad(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_insc_fechas CHECK (fecha_baja IS NULL OR fecha_baja >= fecha_alta),
  INDEX idx_insc_socio (socio_id, estado),
  INDEX idx_insc_actividad (actividad_id, estado)
) ENGINE=InnoDB;

-- Ledger: movimientos de cuenta
CREATE TABLE movimiento_cuenta (
  id               BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT,
  cuenta_id        BIGINT UNSIGNED NOT NULL,
  fecha            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  tipo             ENUM('ALTA_SOCIO_CUOTA_CLUB','PAGO','INSCRIPCION_ACTIVIDAD',
                        'AJUSTE_DEBITO','AJUSTE_CREDITO','BAJA_REINTEGRO') NOT NULL,
  descripcion      VARCHAR(160) NULL,
  importe          DECIMAL(14,2) NOT NULL,   -- crédito > 0, débito < 0
  referencia_ext   VARCHAR(120) NULL,
  inscripcion_id   BIGINT UNSIGNED NULL,
  CONSTRAINT fk_mc_cuenta      FOREIGN KEY (cuenta_id)      REFERENCES cuenta(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_mc_inscripcion FOREIGN KEY (inscripcion_id) REFERENCES inscripcion(id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  INDEX idx_mc_cuenta_fecha (cuenta_id, fecha),
  INDEX idx_mc_tipo (tipo),
  CONSTRAINT chk_mc_importe_no_cero CHECK (importe <> 0)
) ENGINE=InnoDB;

-- =========================
-- TRIGGERS (para setear fecha_alta automáticamente)
-- =========================
DELIMITER //

DROP TRIGGER IF EXISTS trg_socio_set_fecha_alta//
CREATE TRIGGER trg_socio_set_fecha_alta
BEFORE INSERT ON socio
FOR EACH ROW
BEGIN
  -- También cubre '0000-00-00' (MariaDB no estricto)
  IF NEW.fecha_alta IS NULL OR NEW.fecha_alta = '0000-00-00' THEN
    SET NEW.fecha_alta = CURDATE();
  END IF;
END//

DROP TRIGGER IF EXISTS trg_insc_set_fecha_alta//
CREATE TRIGGER trg_insc_set_fecha_alta
BEFORE INSERT ON inscripcion
FOR EACH ROW
BEGIN
  -- También cubre '0000-00-00' (MariaDB no estricto)
  IF NEW.fecha_alta IS NULL OR NEW.fecha_alta = '0000-00-00' THEN
    SET NEW.fecha_alta = CURDATE();
  END IF;
END//

DELIMITER ;

-- =========================
-- VISTAS (útiles para control)
-- =========================

CREATE OR REPLACE VIEW vw_estado_cuenta_por_socio AS
SELECT
  s.id              AS socio_id,
  s.dni,
  CONCAT(s.apellido, ', ', s.nombre) AS socio,
  COALESCE(SUM(m.importe),0)         AS saldo,
  COALESCE(SUM(CASE WHEN m.importe < 0 THEN -m.importe END),0) AS total_debitos,
  COALESCE(SUM(CASE WHEN m.importe > 0 THEN  m.importe END),0) AS total_creditos
FROM socio s
LEFT JOIN cuenta c            ON c.socio_id = s.id
LEFT JOIN movimiento_cuenta m ON m.cuenta_id = c.id
GROUP BY s.id, s.dni, socio;

CREATE OR REPLACE VIEW vw_movimientos_detalle AS
SELECT
  m.id, m.fecha, m.tipo, m.descripcion, m.importe, m.referencia_ext,
  s.id AS socio_id, s.dni, CONCAT(s.apellido, ', ', s.nombre) AS socio,
  a.nombre AS actividad
FROM movimiento_cuenta m
JOIN cuenta c         ON c.id = m.cuenta_id
JOIN socio  s         ON s.id = c.socio_id
LEFT JOIN inscripcion i ON i.id = m.inscripcion_id
LEFT JOIN actividad  a  ON a.id = i.actividad_id;

-- =========================
-- DATOS INICIALES
-- =========================

-- Admin
INSERT INTO administrador (nombre, apellido, email, password_hash, estado)
VALUES ('Admin', 'CSP', 'admin@csp.local', '$2y$12$hash_de_ejemplo_reemplazar', 'ACTIVO')
ON DUPLICATE KEY UPDATE email=email;

-- Parámetros (cuotas)
INSERT INTO parametros_globales (clave, valor_num, descripcion) VALUES
  ('cuota_club', 10000.00, 'Cuota inicial del club al dar de alta al socio'),
  ('CUOTA_MENSUAL_CLUB', 150000.00, 'Cuota mensual vigente del club')
ON DUPLICATE KEY UPDATE valor_num=VALUES(valor_num), descripcion=VALUES(descripcion);

-- Socios (DNIs únicos)
INSERT INTO socio (dni, nombre, apellido, email, telefono) VALUES
('30111223', 'Ana',       'López',      'analopez@gmail.com',           '11-5555-1111'),
('31915282', 'Carolina',  'Pettinaroli','carolinapettinaroli@gmail.com','11-5555-0000'),
('28765432', 'Juan',      'Giménez',    'juan.gimenez@example.com',     '11-4000-0001'),
('29555111', 'María',     'Fernández',  'maria.fernandez@example.com',  '11-4000-0002'),
('31222333', 'Lucía',     'Pérez',      'lucia.perez@example.com',      '11-4000-0003'),
('33444555', 'Sofía',     'Martínez',   'sofia.martinez@example.com',   '11-4000-0004'),
('27666999', 'Diego',     'Suárez',     'diego.suarez@example.com',     '11-4000-0005'),
('30555777', 'Valeria',   'Gómez',      'valeria.gomez@example.com',    '11-4000-0006'),
('29888999', 'Nicolás',   'Domínguez',  'nicolas.dominguez@example.com','11-4000-0007'),
('32222444', 'Camila',    'Rossi',      'camila.rossi@example.com',     '11-4000-0008')
ON DUPLICATE KEY UPDATE email=VALUES(email), telefono=VALUES(telefono);

-- Cuentas (crear la que falte para cada socio)
INSERT INTO cuenta (socio_id)
SELECT s.id
FROM socio s
LEFT JOIN cuenta c ON c.socio_id = s.id
WHERE c.socio_id IS NULL;

-- Aptos médicos (algunos socios)
INSERT INTO apto_medico (socio_id, fecha_emision, fecha_vencimiento)
SELECT id, '2025-05-01', '2026-05-31' FROM socio WHERE dni IN ('31915282')
ON DUPLICATE KEY UPDATE fecha_emision=VALUES(fecha_emision), fecha_vencimiento=VALUES(fecha_vencimiento);

INSERT INTO apto_medico (socio_id, fecha_emision, fecha_vencimiento)
SELECT id, '2025-03-15', '2026-03-15' FROM socio WHERE dni IN ('30111223','28765432')
ON DUPLICATE KEY UPDATE fecha_emision=VALUES(fecha_emision), fecha_vencimiento=VALUES(fecha_vencimiento);

-- Actividades
INSERT INTO actividad (nombre, descripcion, precio_default) VALUES
('Fútbol',           'Entrenamientos y liga interna',              60000.00),
('Natación',         'Clases por niveles',                          80000.00),
('Gimnasia',         'Acondicionamiento físico general',            40000.00),
('Yoga',             'Yoga integral',                               45000.00),
('Pilates',          'Pilates suelo y/o reformer',                  85000.00),
('Básquet',          'Entrenamientos y recreativo',                 55000.00),
('Tenis',            'Escuela y canchas por turnos',                90000.00),
('Patín',            'Artístico y recreativo',                      50000.00),
('Vóley',            'Mixto recreativo y entrenamientos',           52000.00),
('Funcional',        'Entrenamiento funcional en grupos',           48000.00),
('Zumba',            'Clases grupales de baile',                    38000.00),
('Taekwondo',        'Arte marcial – todos los niveles',            62000.00)
ON DUPLICATE KEY UPDATE descripcion=VALUES(descripcion), precio_default=VALUES(precio_default);

-- Inscripciones
-- Carolina (31915282) -> Fútbol
INSERT INTO inscripcion (socio_id, actividad_id)
SELECT s.id, a.id
FROM socio s JOIN actividad a ON a.nombre='Fútbol'
WHERE s.dni='31915282';

-- Ana (30111223) -> Natación y Yoga
INSERT INTO inscripcion (socio_id, actividad_id)
SELECT s.id, a.id FROM socio s JOIN actividad a ON a.nombre='Natación'
WHERE s.dni='30111223';

INSERT INTO inscripcion (socio_id, actividad_id)
SELECT s.id, a.id FROM socio s JOIN actividad a ON a.nombre='Yoga'
WHERE s.dni='30111223';

-- Juan (28765432) -> Gimnasia
INSERT INTO inscripcion (socio_id, actividad_id)
SELECT s.id, a.id FROM socio s JOIN actividad a ON a.nombre='Gimnasia'
WHERE s.dni='28765432';

-- =========================================================
-- PROCEDIMIENTO PARA COBRANZA AUTOMÁTICA (club + actividades)
-- =========================================================
DELIMITER //

DROP PROCEDURE IF EXISTS sp_cobrar_mes//
CREATE PROCEDURE sp_cobrar_mes(IN p_anio INT, IN p_mes INT)
BEGIN
  DECLARE v_first DATE;
  DECLARE v_last  DATE;

  -- Rango del mes
  SET v_first = STR_TO_DATE(CONCAT(p_anio,'-',LPAD(p_mes,2,'0'),'-01'), '%Y-%m-%d');
  SET v_last  = LAST_DAY(v_first);

  -- 1) CUOTA MENSUAL DEL CLUB (una por cuenta y mes)
  INSERT INTO movimiento_cuenta (cuenta_id, fecha, tipo, descripcion, importe)
  SELECT c.id,
         NOW(),
         'ALTA_SOCIO_CUOTA_CLUB',
         CONCAT('Cuota mensual ', LPAD(p_mes,2,'0'), '/', p_anio),
         -pg.valor_num
  FROM socio s
  JOIN cuenta c ON c.socio_id = s.id
  JOIN parametros_globales pg ON pg.clave = 'CUOTA_MENSUAL_CLUB'
  WHERE s.estado = 'ACTIVO'
    AND s.fecha_alta <= v_last
    AND (s.fecha_baja IS NULL OR s.fecha_baja >= v_first)
    AND NOT EXISTS (  -- ya cobrado ese mes?
      SELECT 1 FROM movimiento_cuenta m
      WHERE m.cuenta_id = c.id
        AND m.tipo = 'ALTA_SOCIO_CUOTA_CLUB'
        AND YEAR(m.fecha) = p_anio
        AND MONTH(m.fecha) = p_mes
    );

  -- 2) CUOTAS MENSUALES DE ACTIVIDADES (una por inscripción y mes)
  INSERT INTO movimiento_cuenta (cuenta_id, fecha, tipo, descripcion, importe, inscripcion_id)
  SELECT c.id,
         NOW(),
         'INSCRIPCION_ACTIVIDAD',  -- reutilizado como “cuota mensual de actividad”
         CONCAT('Cuota ', a.nombre, ' ', LPAD(p_mes,2,'0'), '/', p_anio),
         -a.precio_default,
         i.id
  FROM inscripcion i
  JOIN socio s     ON s.id = i.socio_id
  JOIN cuenta c    ON c.socio_id = s.id
  JOIN actividad a ON a.id = i.actividad_id
  WHERE i.estado = 'ACTIVA'
    AND a.precio_default IS NOT NULL
    AND i.fecha_alta <= v_last
    AND (i.fecha_baja IS NULL OR i.fecha_baja >= v_first)
    AND NOT EXISTS (  -- ya cobrada esa inscripción ese mes?
      SELECT 1 FROM movimiento_cuenta m
      WHERE m.cuenta_id = c.id
        AND m.tipo = 'INSCRIPCION_ACTIVIDAD'
        AND m.inscripcion_id = i.id
        AND YEAR(m.fecha) = p_anio
        AND MONTH(m.fecha) = p_mes
    );

END//
DELIMITER ;

-- Evento automático diario a las 02:00 (el SP evita duplicar)
SET GLOBAL event_scheduler = ON;

DROP EVENT IF EXISTS ev_cobro_cuotas_diario;
CREATE EVENT ev_cobro_cuotas_diario
ON SCHEDULE EVERY 1 DAY
STARTS CURRENT_DATE + INTERVAL 2 HOUR
DO
  CALL sp_cobrar_mes(YEAR(CURDATE()), MONTH(CURDATE()));

-- Correr la cobranza del mes en curso una vez ahora
CALL sp_cobrar_mes(YEAR(CURDATE()), MONTH(CURDATE()));

-- Registrar un pago manual 
INSERT INTO movimiento_cuenta (cuenta_id, tipo, descripcion, importe, referencia_ext)
VALUES (
  (SELECT c.id
   FROM socio s JOIN cuenta c ON c.socio_id = s.id
   WHERE s.dni = '31915282'
   LIMIT 1),
  'PAGO', 'Pago en caja', 150000.00, 'REC-0001'
);

/* PRUEBAS 
Alta de socio en el club con creación de cuenta
INSERT INTO socio (dni, nombre, apellido, email, telefono, domicilio)
VALUES ('40111222','Pedro','Sosa','pedro.sosa@example.com','11-4444-0000','Av. Siempre Viva 123');

INSERT INTO cuenta (socio_id)
SELECT s.id FROM socio s
LEFT JOIN cuenta c ON c.socio_id = s.id
WHERE s.dni='40111222' AND c.socio_id IS NULL;

Carga de apto médico
INSERT INTO apto_medico (socio_id, fecha_emision, fecha_vencimiento, observaciones)
SELECT id, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 1 YEAR), 'Apto inicial'
FROM socio WHERE dni='40111222'
ON DUPLICATE KEY UPDATE observaciones='Apto inicial';

Inscripción de socio a actividad
INSERT INTO inscripcion (socio_id, actividad_id)
SELECT s.id, a.id
FROM socio s JOIN actividad a ON a.nombre='Tenis'
WHERE s.dni='40111222';

Actualización de domicilio de socio
UPDATE socio SET domicilio='Calle Actualizada 456'
WHERE dni='40111222';

Actualización de estado de socio a Inactivo por baja del club
UPDATE socio
SET estado='INACTIVO', fecha_baja=CURDATE()
WHERE dni='40111222';

Extensión de vigencia del apto médico por un añoptimize
UPDATE apto_medico am
JOIN socio s ON s.id=am.socio_id
SET am.fecha_vencimiento = DATE_ADD(am.fecha_vencimiento, INTERVAL 1 YEAR)
WHERE s.dni='30111223';

Baja de socio de una actividad
-- (a) Crédito opcional por reintegro de cuota de actividad 
INSERT INTO movimiento_cuenta (cuenta_id, tipo, descripcion, importe, inscripcion_id)
SELECT c.id, 'BAJA_REINTEGRO', 'Reintegro por baja en Yoga', a.precio_default / 2, i.id
FROM inscripcion i
JOIN socio s     ON s.id = i.socio_id  AND s.dni='30111223'
JOIN actividad a ON a.id = i.actividad_id AND a.nombre='Yoga'
JOIN cuenta c    ON c.socio_id = s.id
LIMIT 1;

-- (b) Baja lógica de la inscripción
UPDATE inscripcion i
JOIN socio s     ON s.id = i.socio_id  AND s.dni='30111223'
JOIN actividad a ON a.id = i.actividad_id AND a.nombre='Yoga'
SET i.estado='BAJA', i.fecha_baja=CURDATE()
LIMIT 1;

*/



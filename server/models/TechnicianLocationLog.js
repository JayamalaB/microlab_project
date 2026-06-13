'use strict';

const { DataTypes } = require('sequelize');
const sequelize = require('./sequelize');

module.exports = sequelize.define('TechnicianLocationLog', {
  log_id:          { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  technician_id:   { type: DataTypes.INTEGER, allowNull: false },
  session_id:      DataTypes.INTEGER,
  booking_id:      DataTypes.INTEGER,
  latitude:        DataTypes.DECIMAL(10, 7),
  longitude:       DataTypes.DECIMAL(10, 7),
  accuracy_meters: DataTypes.FLOAT,
  altitude_meters: DataTypes.FLOAT,
  speed_kmph:      DataTypes.FLOAT,
  bearing_degrees: DataTypes.FLOAT,
  task_status:     DataTypes.STRING(50),
  battery_level:   DataTypes.TINYINT,
  network_type:    DataTypes.STRING(20),
  is_mocked:       DataTypes.TINYINT,
  source:          DataTypes.STRING(50),
  device_timestamp: DataTypes.DATE,
  created_at:      DataTypes.DATE,
}, { tableName: 'technician_location_log', timestamps: false });

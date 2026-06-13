'use strict';

const { DataTypes } = require('sequelize');
const sequelize = require('./sequelize');

module.exports = sequelize.define('TechnicianLiveLocation', {
  live_id:            { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  technician_id:      { type: DataTypes.INTEGER, allowNull: false, unique: true },
  socket_id:          DataTypes.STRING(100),
  session_id:         DataTypes.INTEGER,
  current_booking_id: DataTypes.INTEGER,
  latitude:           DataTypes.DECIMAL(10, 7),
  longitude:          DataTypes.DECIMAL(10, 7),
  accuracy_meters:    DataTypes.FLOAT,
  speed_kmph:         DataTypes.FLOAT,
  bearing_degrees:    DataTypes.FLOAT,
  address_label:      DataTypes.STRING(255),
  last_ping_at:       DataTypes.DATE,
  online_status:      DataTypes.STRING(20),
  task_status:        DataTypes.STRING(50),
  battery_level:      DataTypes.TINYINT,
  updated_at:         DataTypes.DATE,
}, { tableName: 'technician_live_location', timestamps: false });

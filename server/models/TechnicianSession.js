'use strict';

const { DataTypes } = require('sequelize');
const sequelize = require('./sequelize');

module.exports = sequelize.define('TechnicianSession', {
  session_id:                { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  technician_id:             { type: DataTypes.INTEGER, allowNull: false },
  session_status:            DataTypes.STRING(50),
  availability_status:       DataTypes.STRING(50),
  total_bookings_assigned:   { type: DataTypes.SMALLINT, defaultValue: 0 },
  total_bookings_completed:  { type: DataTypes.SMALLINT, defaultValue: 0 },
  total_distance_km:         DataTypes.DECIMAL(8, 2),
  total_pings:               { type: DataTypes.INTEGER, defaultValue: 0 },
  created_at:                DataTypes.DATE,
  updated_at:                DataTypes.DATE,
}, { tableName: 'technician_session', timestamps: false });

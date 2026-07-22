'use strict';

const sequelize               = require('./sequelize');
const BookingRequest          = require('./BookingRequest');
const TechnicianLiveLocation  = require('./TechnicianLiveLocation');
const TechnicianLocationLog   = require('./TechnicianLocationLog');
const TechnicianSession       = require('./TechnicianSession');
const TechnicianCollectionBooking = require('./TechnicianCollectionBooking');
const PatientTrackingData     = require('./PatientTrackingData');

sequelize.sync({ alter: false }).catch(err =>
  console.error('[Sequelize] sync error:', err.message)
);

module.exports = {
  sequelize,
  BookingRequest,
  TechnicianLiveLocation,
  TechnicianLocationLog,
  TechnicianSession,
  TechnicianCollectionBooking,
  PatientTrackingData,
};

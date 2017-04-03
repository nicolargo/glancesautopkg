Glances autopackage builder
===========================

This repo aims at building RPM, DEB and self-extracting SH for Glances.

Pre-requisites
==============

Packages are build thanks to the fpm software.

First of all, we need to install it (with root right):

.. code-block:: console

    gem install fpm

Note: on Ubuntu, *gem* is available in the *ruby* package. You also need to
install *ruby-dev*.

Build the RPM package
=====================

Enter the following command line:

.. code-block:: console

    fpm -s python -t rpm glances

Build the DEB package
=====================

Enter the following command line:

.. code-block:: console

    fpm -s python -t deb glances

Build the self-extracting SH installer
======================================

Enter the following command line:

.. code-block:: console

    fpm -s python -t sh glances

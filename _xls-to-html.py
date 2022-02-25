# _xls-to-html.py
# 
# 
# 
# 
import csv
import os
import pandas as pd
import re
import openpyxl
import validators
import re
import shutil
import time 

file_dir = '/Users/paulb.sizemore/OneDrive/_github/data_csv-to-html-links/'
log_text = ''
files = [  f for f in os.listdir(file_dir)  if f.endswith(".xlsx")]

#####################################################################
#####################################################################
# Loop the Excel Files
for i in files:
    siteName = i.replace(".xlsx","")

    excelFileOriginal = file_dir + i
    excelFile = file_dir + siteName + '/' + i
    siteDirectory = file_dir + siteName
    csvFileList = ['']
    if not os.path.exists(siteDirectory):
        os.makedirs(siteDirectory)

    try:
        shutil.move(excelFileOriginal, excelFile)
    except Exception as e:
        print("Error: " + e.__str__())

    wb=openpyxl.load_workbook(excelFile)
    sheetNames = wb.sheetnames

    print('-----------------------------------------------')
    print(' Site Name: ' + siteName)
    print('Excel Path: ' + excelFile)
    print('\n')
    #####################################################################
    #####################################################################
    # Loop the sheet names in the Excel file to find external links 
    for ws in wb:
        csvFile = excelFile.replace(".xlsx","_") + ws.title.lower()  + '.csv'
        htmlFile = csvFile.replace(".csv",".html")
        htmlTitle = (ws.title.replace("_"," ")).capitalize()

        ##########################################
        # Prepare the contents of the CSV file
        rowOutput = ''

        for row in ws.values:
            for value in row:
                cleanValue = str(value)
                cleanValue = cleanValue.replace('"','\\"')
                rowOutput = str(rowOutput) + '"' + cleanValue + '",'

            rowOutput = rowOutput + '""\n'

        ##################################################
        # Save the CSV file
        with open(csvFile, "a") as text_file:
            print(rowOutput, file=text_file)


        print(' CSV Path: ' + csvFile)



        df = pd.read_csv(csvFile)



    ######################################################################
    # Generate the Index file 
    file_path = siteDirectory + '/index.html'
    print('Index file to create: ' + file_path)

    htmlOut = '<!DOCTYPE HTML><html><head><style>body {font-family: Arial, Helvetica, sans-serif;} </style></head><body><h3></h3><h2>' + i + '</h2>'
    files = [ f for f in os.listdir(siteDirectory) if f.endswith(".html")]


    if len(files) > 0:
        for k in files: 

            title = k.replace('.html','')
            title = title.replace(i,'')
            title = title.replace('_',' ')
            print('Title: ' + title)
            print('Linked File: ' + k)

            htmlOut = htmlOut + '<p><a href="./' + k +  '">' + title + '</a></p>'


        htmlOut = htmlOut + '</body></html>	'

    else: 
        print('NO HTML FILES FOUND IN FOLDER SO INDEX.HTML NOT GENERATED')
        htmlOut = ''

    if len(htmlOut) > 1: 
        text_out = htmlOut
        with open(file_path, "w") as text_file:
            print(text_out, file=text_file)   



















file_name = file_dir + '_error.log'
with open(file_name, "w") as text_file:
    print(log_text, file=text_file)
Option Explicit

Sub FormatFlaggedTransactions()
    Dim oDoc As Object
    Dim oSheet As Object
    Dim oCursor As Object
    Dim lastRow As Long
    Dim lastCol As Long
    Dim amountCol As Long
    Dim flagCol As Long
    Dim txnIdCol As Long
    Dim tsCol As Long
    Dim r As Long
    Dim c As Long
    Dim header As String
    Dim flaggedCount As Long
    Dim totalCount As Long
    Dim totalAmount As Double
    Dim flaggedAmount As Double
    Dim flagRate As Double
    Dim amountAtRiskRate As Double

    oDoc = ThisComponent
    oSheet = oDoc.CurrentController.ActiveSheet
    oCursor = oSheet.createCursor()
    oCursor.gotoEndOfUsedArea(True)
    lastRow = oCursor.RangeAddress.EndRow
    lastCol = oCursor.RangeAddress.EndColumn

    amountCol = -1
    flagCol = -1
    txnIdCol = -1
    tsCol = -1

    '---------------------------------------
    ' Find required and optional columns
    '---------------------------------------
    For c = 0 To lastCol
        header = Trim(LCase(oSheet.getCellByPosition(c, 0).String))
        If header = "amount" Then amountCol = c
        If header = "biometric_evasion_flag" Then flagCol = c
        If header = "transaction_id" Then txnIdCol = c
        If header = "timestamp" Then tsCol = c
    Next c

    If amountCol = -1 Then
        MsgBox "Column 'amount' not found.", 16, "Error"
        Exit Sub
    End If
    If flagCol = -1 Then
        MsgBox "Column 'biometric_evasion_flag' not found.", 16, "Error"
        Exit Sub
    End If

    totalCount = lastRow  ' data occupies rows 1..lastRow (row 0 is the header)

    '---------------------------------------
    ' Style Header
    '---------------------------------------
    For c = 0 To lastCol
        With oSheet.getCellByPosition(c, 0)
            .CharWeight = com.sun.star.awt.FontWeight.BOLD
            .CellBackColor = RGB(31, 78, 121)
            .CharColor = RGB(255, 255, 255)
        End With
    Next c

    '---------------------------------------
    ' Number Formats (currency + percent), reused across both sheets
    '---------------------------------------
    Dim nf As Object
    Dim locale As New com.sun.star.lang.Locale
    locale.Language = "en"
    locale.Country = "US"
    nf = oDoc.getNumberFormats()

    Dim currencyFormat As Long
    currencyFormat = nf.queryKey("#,##0 ""VND""", locale, True)
    If currencyFormat = -1 Then
        currencyFormat = nf.addNew("#,##0 ""VND""", locale)
    End If

    Dim percentFormat As Long
    percentFormat = nf.queryKey("0.0%", locale, True)
    If percentFormat = -1 Then
        percentFormat = nf.addNew("0.0%", locale)
    End If

    For r = 1 To lastRow
        oSheet.getCellByPosition(amountCol, r).NumberFormat = currencyFormat
    Next r

    '---------------------------------------
    ' Highlight Fraud Rows + accumulate Tier A metrics
    ' (count AND amount, since board reporting needs both the number of
    ' incidents and the financial exposure they represent)
    '---------------------------------------
    Dim topN As Integer
    topN = 10
    Dim topAmt(1 To 10) As Double
    Dim topTxnId(1 To 10) As String
    Dim topTime(1 To 10) As String
    Dim i As Integer
    For i = 1 To topN
        topAmt(i) = -1
        topTxnId(i) = ""
        topTime(i) = ""
    Next i

    flaggedCount = 0
    totalAmount = 0
    flaggedAmount = 0

    For r = 1 To lastRow
        Dim flag As String
        Dim amt As Double
        flag = LCase(Trim(oSheet.getCellByPosition(flagCol, r).String))
        amt = oSheet.getCellByPosition(amountCol, r).Value

        totalAmount = totalAmount + amt

        If flag = "true" Then
            flaggedCount = flaggedCount + 1
            flaggedAmount = flaggedAmount + amt

            For c = 0 To lastCol
                oSheet.getCellByPosition(c, r).CellBackColor = RGB(255, 199, 206)
                oSheet.getCellByPosition(c, r).CharColor = RGB(156, 0, 6)
            Next c

            ' --- maintain a running top-10-by-amount list without sorting the full dataset ---
            If amt > topAmt(topN) Then
                Dim pos As Integer
                Dim txnIdStr As String
                Dim tsStr As String

                If txnIdCol <> -1 Then
                    txnIdStr = CStr(CLng(oSheet.getCellByPosition(txnIdCol, r).Value))
                Else
                    txnIdStr = "Row " & (r + 1)
                End If

                If tsCol <> -1 Then
                    tsStr = oSheet.getCellByPosition(tsCol, r).String
                Else
                    tsStr = ""
                End If

                pos = topN
                Do While pos > 1
                    If amt > topAmt(pos - 1) Then
                        topAmt(pos) = topAmt(pos - 1)
                        topTxnId(pos) = topTxnId(pos - 1)
                        topTime(pos) = topTime(pos - 1)
                        pos = pos - 1
                    Else
                        Exit Do
                    End If
                Loop
                topAmt(pos) = amt
                topTxnId(pos) = txnIdStr
                topTime(pos) = tsStr
            End If
        End If
    Next r

    If totalCount > 0 Then
        flagRate = flaggedCount / totalCount
    Else
        flagRate = 0
    End If

    If totalAmount > 0 Then
        amountAtRiskRate = flaggedAmount / totalAmount
    Else
        amountAtRiskRate = 0
    End If

    '---------------------------------------
    ' Insert Summary Banner (on the data sheet itself)
    '---------------------------------------
    oSheet.Rows.insertByIndex(0, 3)

    With oSheet.getCellByPosition(0, 0)
        .String = "FLAGGED TRANSACTION REPORT"
        .CharWeight = com.sun.star.awt.FontWeight.BOLD
        .CharHeight = 16
    End With
    With oSheet.getCellByPosition(0, 1)
        .String = "Total: " & totalCount & "   |   Flagged: " & flaggedCount & _
                   "   |   Flag Rate: " & Format(flagRate * 100, "0.0") & "%"
        .CharWeight = com.sun.star.awt.FontWeight.BOLD
    End With
    With oSheet.getCellByPosition(0, 2)
        .String = "Amount at Risk: " & Format(flaggedAmount, "#,##0") & " VND" & _
                   "   |   Share of Total Volume: " & Format(amountAtRiskRate * 100, "0.0") & "%"
        .CharWeight = com.sun.star.awt.FontWeight.BOLD
    End With

    '---------------------------------------
    ' Freeze Header, Auto-size Columns (data sheet)
    '---------------------------------------
    oDoc.CurrentController.freezeAtPosition(0, 4)

    Dim cols As Object
    cols = oSheet.Columns
    For c = 0 To lastCol
        cols.getByIndex(c).OptimalWidth = True
    Next c

    '---------------------------------------
    ' Build the Executive Summary sheet
    '---------------------------------------
    If oDoc.Sheets.hasByName("Executive Summary") Then
        oDoc.Sheets.removeByName("Executive Summary")
    End If
    oDoc.Sheets.insertNewByName("Executive Summary", 0)
    Dim oSummary As Object
    oSummary = oDoc.Sheets.getByName("Executive Summary")

    Dim sourceName As String
    sourceName = oDoc.getTitle()
    If sourceName = "" Then
        sourceName = "(unsaved workbook)"
    End If

    Dim row As Long
    row = 0

    With oSummary.getCellByPosition(0, row)
        .String = "WALLEY RISK FRAUD PLATFORM — EXECUTIVE SUMMARY"
        .CharWeight = com.sun.star.awt.FontWeight.BOLD
        .CharHeight = 16
        .CellBackColor = RGB(31, 56, 100)
        .CharColor = RGB(255, 255, 255)
    End With
    row = row + 1

    oSummary.getCellByPosition(0, row).String = "Report generated: " & Format(Now, "YYYY-MM-DD HH:MM")
    row = row + 1
    oSummary.getCellByPosition(0, row).String = "Source file: " & sourceName
    row = row + 2

    Dim labels(6) As String
    Dim values(6) As String
    labels(0) = "Total Transactions"       : values(0) = Format(totalCount, "#,##0")
    labels(1) = "Flagged Transactions"     : values(1) = Format(flaggedCount, "#,##0")
    labels(2) = "Flag Rate (by count)"     : values(2) = Format(flagRate * 100, "0.0") & "%"
    labels(3) = "Total Transaction Volume" : values(3) = Format(totalAmount, "#,##0") & " VND"
    labels(4) = "Amount at Risk (flagged)" : values(4) = Format(flaggedAmount, "#,##0") & " VND"
    labels(5) = "Share of Total Volume"    : values(5) = Format(amountAtRiskRate * 100, "0.0") & "%"

    For i = 0 To 5
        With oSummary.getCellByPosition(0, row)
            .String = labels(i)
            .CharWeight = com.sun.star.awt.FontWeight.BOLD
        End With
        oSummary.getCellByPosition(1, row).String = values(i)
        row = row + 1
    Next i

    row = row + 1
    With oSummary.getCellByPosition(0, row)
        .String = "TOP 10 HIGHEST-VALUE FLAGGED TRANSACTIONS"
        .CharWeight = com.sun.star.awt.FontWeight.BOLD
        .CharHeight = 12
        .CellBackColor = RGB(217, 226, 243)
    End With
    row = row + 1

    Dim tblHeaderRow As Long
    tblHeaderRow = row
    oSummary.getCellByPosition(0, row).String = "Rank"
    oSummary.getCellByPosition(1, row).String = "Transaction ID"
    oSummary.getCellByPosition(2, row).String = "Timestamp"
    oSummary.getCellByPosition(3, row).String = "Amount (VND)"
    For c = 0 To 3
        With oSummary.getCellByPosition(c, row)
            .CharWeight = com.sun.star.awt.FontWeight.BOLD
            .CellBackColor = RGB(68, 114, 196)
            .CharColor = RGB(255, 255, 255)
        End With
    Next c
    row = row + 1

    For i = 1 To topN
        If topAmt(i) >= 0 Then
            oSummary.getCellByPosition(0, row).Value = i
            oSummary.getCellByPosition(1, row).String = topTxnId(i)
            oSummary.getCellByPosition(2, row).String = topTime(i)
            With oSummary.getCellByPosition(3, row)
                .Value = topAmt(i)
                .NumberFormat = currencyFormat
            End With
            row = row + 1
        End If
    Next i

    Dim summaryCols As Object
    summaryCols = oSummary.Columns
    For c = 0 To 3
        summaryCols.getByIndex(c).OptimalWidth = True
    Next c

    ' Show the board-facing summary sheet first when the file opens
    oDoc.CurrentController.setActiveSheet(oSummary)

    MsgBox "Report formatted successfully!" & Chr(10) & _
           "Flagged: " & flaggedCount & " of " & totalCount & _
           " (" & Format(flagRate * 100, "0.0") & "%)" & Chr(10) & _
           "Amount at risk: " & Format(flaggedAmount, "#,##0") & " VND" & _
           " (" & Format(amountAtRiskRate * 100, "0.0") & "% of total volume)", _
           64, "Walley Risk Fraud Platform"

End Sub